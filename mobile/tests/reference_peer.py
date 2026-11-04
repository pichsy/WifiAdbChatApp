#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文件互传助手 · 移动端协议参考对端（Python 3，零第三方依赖）。

用途
----
在 Android / iOS App 之外，用纯 Python 模拟「电脑端」，按
docs/LAN-transfer-spec.md 的契约完成设备发现、6 位配对码配对、文字与文件收发；
既可以作为联调对端（CLI），也可以被测试脚本 import 当作协议库使用。

CLI 子命令
----------
  serve       作为电脑端常驻：UDP 52730 发现 + TCP 接收，打印配对请求、收到的文字/文件
  discover    只监听 UDP 52730，列出发现的设备（不广播、不占 TCP 端口）
  pair        只做一次 TCP 握手配对（不发内容）
  send-text   发现/直连对端，握手后发送一段文字
  send-file   发现/直连对端，握手后发送一个文件（256 KiB 分块）
  info        打印本机参考对端身份、已配对 ID 与默认路径

常用示例：

    # 电脑端（等待手机来发现/配对/发送）
    python3 mobile/tests/reference_peer.py serve --name "QA 电脑" --code 123456

    # 列出局域网里的设备（含手机 App 通告的 TCP 端口）
    python3 mobile/tests/reference_peer.py discover --seconds 5

    # 主动发给手机 App（手机屏幕上显示的 6 位配对码）
    python3 mobile/tests/reference_peer.py send-text --host 192.168.1.23 --port 54321 --code 123456 --text "你好，手机端 👋"
    python3 mobile/tests/reference_peer.py send-file --peer "iPhone 17" --code 123456 --file ./测试文件.bin

退出码：0 成功；1 失败；2 参数/用法错误；3 需要配对（对端回了 pair_required）。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import signal
import socket
import struct
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# 协议常量（docs/LAN-transfer-spec.md）
# ---------------------------------------------------------------------------

APP_TAG = "ADBTypeLink"
PROTOCOL_VERSION = 1
DISCOVERY_PORT = 52730
MAX_FRAME_BYTES = 16 * 1024 * 1024
FILE_CHUNK_BYTES = 256 * 1024
CONNECT_TIMEOUT_SECONDS = 6.0
IO_TIMEOUT_SECONDS = 30.0
DEFAULT_ANNOUNCE_INTERVAL = 2.0
DEFAULT_OFFLINE_AFTER = 8.0
DEFAULT_PRUNE_INTERVAL = 3.0
PAIR_CODE_DIGITS = 6

HELLO_ERROR_MESSAGE = "协议不匹配，请升级两端应用"
SAVE_FAILED_MESSAGE = "保存文件失败"
PROTOCOL_MISMATCH_MESSAGE = "协议不匹配，请确认两端版本一致"
NO_RESPONSE_MESSAGE = "对方没有响应"
WRONG_CODE_MESSAGE = "配对码不对，再看一眼对方屏幕上显示的数字"
EMPTY_TEXT_MESSAGE = "先输入要发送的文字"
TEXT_NOT_ACKED_MESSAGE = "发送文字失败，对方没有确认"
FILE_NOT_ACKED_MESSAGE = "对方没有确认收到文件"
BAD_PAIR_CODE_MESSAGE = "配对码是 6 位数字"

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_STATE_DIR = BASE_DIR / ".state"
DEFAULT_RECEIVE_DIR = BASE_DIR / "received"

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_NEED_PAIR = 3


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------


def now_seconds() -> float:
    """墙上时间，只用于日志展示。"""
    return time.time()


def make_pairing_code() -> str:
    """生成 6 位配对码（保留前导 0）。"""
    return "%06d" % random.SystemRandom().randrange(0, 10 ** PAIR_CODE_DIGITS)


def is_valid_pairing_code(code: object) -> bool:
    return isinstance(code, str) and re.fullmatch("[0-9]{6}", code.strip()) is not None


def normalize_pairing_code(code: object) -> Optional[str]:
    """按 spec 4.3 去掉首尾空白；不是 6 位数字则返回 None。"""
    if not isinstance(code, str):
        return None
    value = code.strip()
    if not re.fullmatch("[0-9]{6}", value):
        return None
    return value


def make_device_id() -> str:
    return str(uuid.uuid4()).upper()


def sanitize_file_name(name: str) -> Optional[str]:
    """按 spec 6 只取路径最后一段；空名 / 单个点 / 双点返回 None。"""
    if not isinstance(name, str):
        return None
    value = name.replace(chr(92), "/").split("/")[-1]
    if value in ("", ".", ".."):
        return None
    return value


def allocate_receive_path(directory: Path, safe_name: str) -> Tuple[Path, str]:
    """重名时依次尝试 base (2).ext、base (3).ext（与 macOS 端一致）。"""
    base, ext = os.path.splitext(safe_name)
    candidate = safe_name
    index = 2
    path = Path(directory) / candidate
    while path.exists():
        candidate = "%s (%d)%s" % (base, index, ext)
        path = Path(directory) / candidate
        index += 1
    return path, candidate


def sha256_file(path: os.PathLike) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(FILE_CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def format_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            if unit == "B":
                return "%d B" % int(value)
            return "%.1f %s" % (value, unit)
        value /= 1024.0
    return "%d B" % size


def wait_until(predicate: Callable[[], object], timeout: float, interval: float = 0.05):
    """轮询 predicate 直到返回真值或超时；超时返回 None。"""
    deadline = time.monotonic() + max(0.0, timeout)
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() >= deadline:
            return None
        time.sleep(interval)


def default_state_path(name: str) -> Path:
    slug = re.sub("[^0-9A-Za-z_-]+", "_", name).strip("_") or "peer"
    digest = hashlib.sha1(name.encode("utf-8")).hexdigest()[:8]
    return DEFAULT_STATE_DIR / ("%s-%s.json" % (slug, digest))


def load_state(path: Optional[os.PathLike]) -> dict:
    if not path:
        return {}
    try:
        obj = json.loads(Path(path).read_text("utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return {}
    return obj if isinstance(obj, dict) else {}


def save_state(path: Optional[os.PathLike], payload: dict) -> None:
    if not path:
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + chr(10), "utf-8")
    os.replace(str(tmp), str(target))


def json_value(value: object) -> str:
    """日志行里给字符串加 JSON 引号，避免空格/中文破坏 key=value 解析。"""
    return json.dumps(value, ensure_ascii=False)


# ---------------------------------------------------------------------------
# 帧格式（spec 3）
# ---------------------------------------------------------------------------


class ProtocolError(Exception):
    """帧非法 / 连接数据不完整。"""


class ConnectionClosed(ProtocolError):
    """对端正常或异常关闭（读到 EOF）。"""


class InvalidMessage(ProtocolError):
    """帧长度合法，但内容不是合法 UTF-8 / JSON 对象（hello 阶段要回 error）。"""


def read_exact(sock: socket.socket, count: int) -> bytes:
    """循环读满 count 字节；不假设一次 recv 到位。"""
    if count < 0:
        raise ProtocolError("负数读取长度")
    chunks: List[bytes] = []
    remaining = count
    while remaining > 0:
        try:
            chunk = sock.recv(remaining)
        except socket.timeout:
            raise ProtocolError("读取超时")
        except OSError as exc:
            raise ProtocolError("读取失败：%s" % exc)
        if not chunk:
            if not chunks:
                raise ConnectionClosed("连接已关闭")
            raise ProtocolError("连接提前关闭：还差 %d 字节" % remaining)
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(sock: socket.socket) -> dict:
    """读取「4 字节大端长度 + UTF-8 JSON」一帧。"""
    header = read_exact(sock, 4)
    length = struct.unpack(">I", header)[0]
    if length <= 0:
        raise ProtocolError("帧长度为 0")
    if length > MAX_FRAME_BYTES:
        raise ProtocolError("帧长度 %d 超过上限 %d" % (length, MAX_FRAME_BYTES))
    body = read_exact(sock, length)
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise InvalidMessage("帧不是合法 UTF-8：%s" % exc)
    try:
        obj = json.loads(text)
    except ValueError as exc:
        raise InvalidMessage("帧不是合法 JSON：%s" % exc)
    if not isinstance(obj, dict):
        raise InvalidMessage("帧内容不是 JSON 对象")
    return obj


def encode_frame(obj: dict) -> bytes:
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    if not body or len(body) > MAX_FRAME_BYTES:
        raise ProtocolError("帧长度非法：%d" % len(body))
    return struct.pack(">I", len(body)) + body


def write_frame(sock: socket.socket, obj: dict) -> None:
    sock.sendall(encode_frame(obj))


def write_frame_best_effort(sock: socket.socket, obj: dict) -> None:
    try:
        write_frame(sock, obj)
    except OSError:
        pass


def set_udp_reuse(sock: socket.socket) -> None:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# 设备发现（spec 2）
# ---------------------------------------------------------------------------


@dataclass
class PeerInfo:
    id: str
    name: str
    host: str
    port: int
    version: int = PROTOCOL_VERSION
    last_seen: float = field(default_factory=time.monotonic)

    @property
    def age(self) -> float:
        return max(0.0, time.monotonic() - self.last_seen)


def validate_announcement(data: bytes, own_id: str, host: str) -> Optional[PeerInfo]:
    """校验一条发现报文；非法返回 None（spec 2.2：静默丢弃）。"""
    try:
        text = data.decode("utf-8")
        obj = json.loads(text)
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(obj, dict):
        return None
    if obj.get("app") != APP_TAG:
        return None
    peer_id = obj.get("id")
    if not isinstance(peer_id, str) or not peer_id.strip() or peer_id == own_id:
        return None
    name = obj.get("name")
    if not isinstance(name, str) or not name.strip():
        return None
    port = obj.get("port")
    # bool 是 int 的子类，必须单独排除；JSON 字符串端口不合法（与 macOS as? Int 一致）。
    if isinstance(port, bool) or not isinstance(port, int) or not (1 <= port <= 65535):
        return None
    version = obj.get("v")
    if isinstance(version, bool) or not isinstance(version, int):
        version = PROTOCOL_VERSION
    return PeerInfo(id=peer_id, name=name, host=host, port=port, version=version)


class DiscoveryError(RuntimeError):
    """UDP 发现无法启动（通常是端口被独占）。"""


class DiscoveryService:
    """UDP 52730 广播 + 监听。

    - 每 2 秒向 255.255.255.255:52730 与 127.0.0.1:52730 广播本机通告；
    - 可选向已知设备（unicast_targets）单播同一份心跳；
    - 监听 0.0.0.0:52730（SO_REUSEADDR + SO_REUSEPORT），8 秒没心跳就移除。
    """

    def __init__(
        self,
        device_id: str,
        device_name: str,
        tcp_port: int,
        discovery_port: int = DISCOVERY_PORT,
        bind_host: str = "0.0.0.0",
        broadcast: bool = True,
        broadcast_targets: Sequence[str] = ("255.255.255.255", "127.0.0.1"),
        unicast_targets: Sequence[str] = (),
        announce_interval: float = DEFAULT_ANNOUNCE_INTERVAL,
        offline_after: float = DEFAULT_OFFLINE_AFTER,
        prune_interval: float = DEFAULT_PRUNE_INTERVAL,
        on_peer: Optional[Callable[[PeerInfo, bool], None]] = None,
        on_peer_lost: Optional[Callable[[PeerInfo], None]] = None,
    ) -> None:
        self.device_id = device_id
        self.device_name = device_name
        self.tcp_port = int(tcp_port)
        self.discovery_port = int(discovery_port)
        self.bind_host = bind_host
        self.broadcast = broadcast
        self.broadcast_targets = tuple(broadcast_targets)
        self.unicast_targets = tuple(unicast_targets)
        self.announce_interval = max(0.05, float(announce_interval))
        self.offline_after = max(0.05, float(offline_after))
        self.prune_interval = max(0.02, float(prune_interval))
        self.on_peer = on_peer
        self.on_peer_lost = on_peer_lost

        self._peers: Dict[str, PeerInfo] = {}
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._recv_sock: Optional[socket.socket] = None
        self._send_sock: Optional[socket.socket] = None
        self._threads: List[threading.Thread] = []
        self._started = False

    # -- 生命周期 ---------------------------------------------------------

    def start(self) -> "DiscoveryService":
        if self._started:
            return self
        recv_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        set_udp_reuse(recv_sock)
        try:
            recv_sock.bind((self.bind_host, self.discovery_port))
        except OSError as exc:
            recv_sock.close()
            raise DiscoveryError(
                "端口 %d 被占用，无法启动局域网发现（%s）。"
                "请确认没有以独占方式绑定该端口的程序；文件互传助手两端都用 SO_REUSEPORT，可并存。"
                % (self.discovery_port, exc)
            ) from exc
        recv_sock.settimeout(0.25)
        self._recv_sock = recv_sock

        send_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        send_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self._send_sock = send_sock
        self._started = True

        self._threads = [
            threading.Thread(target=self._recv_loop, name="discovery-recv", daemon=True),
            threading.Thread(target=self._announce_loop, name="discovery-announce", daemon=True),
            threading.Thread(target=self._prune_loop, name="discovery-prune", daemon=True),
        ]
        for thread in self._threads:
            thread.start()
        self.send_announcement()
        return self

    def stop(self) -> None:
        self._stop.set()
        for sock in (self._recv_sock, self._send_sock):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        self._recv_sock = None
        self._send_sock = None
        for thread in self._threads:
            if thread.is_alive():
                thread.join(1.0)
        self._threads = []
        self._started = False

    # -- 广播 -------------------------------------------------------------

    def announcement_payload(self) -> Optional[bytes]:
        if self.tcp_port <= 0:
            return None
        payload = {
            "app": APP_TAG,
            "v": PROTOCOL_VERSION,
            "id": self.device_id,
            "name": self.device_name,
            "port": self.tcp_port,
        }
        return json.dumps(payload, ensure_ascii=False).encode("utf-8")

    def send_announcement(self, extra_targets: Iterable[str] = ()) -> None:
        payload = self.announcement_payload()
        if payload is None or self._send_sock is None:
            return
        targets: List[str] = []
        if self.broadcast:
            targets.extend(self.broadcast_targets)
        targets.extend(self.unicast_targets)
        targets.extend(extra_targets)
        seen = set()
        for host in targets:
            if not host or host in seen:
                continue
            seen.add(host)
            try:
                self._send_sock.sendto(payload, (host, self.discovery_port))
            except OSError:
                pass

    def _announce_loop(self) -> None:
        while not self._stop.wait(self.announce_interval):
            self.send_announcement()

    # -- 接收 / 清理 ------------------------------------------------------

    def _recv_loop(self) -> None:
        assert self._recv_sock is not None
        while not self._stop.is_set():
            try:
                data, addr = self._recv_sock.recvfrom(8192)
            except socket.timeout:
                continue
            except OSError:
                break
            peer = validate_announcement(data, self.device_id, addr[0])
            if peer is None:
                continue
            with self._lock:
                is_new = peer.id not in self._peers
                self._peers[peer.id] = peer
            self._emit_peer(peer, is_new)

    def _emit_peer(self, peer: PeerInfo, is_new: bool) -> None:
        callback = self.on_peer
        if callback is None:
            return
        try:
            callback(peer, is_new)
        except Exception:  # 回调异常不能影响发现线程
            pass

    def _prune_loop(self) -> None:
        while not self._stop.wait(self.prune_interval):
            deadline = time.monotonic() - self.offline_after
            expired: List[PeerInfo] = []
            with self._lock:
                for peer_id, peer in list(self._peers.items()):
                    if peer.last_seen < deadline:
                        del self._peers[peer_id]
                        expired.append(peer)
            callback = self.on_peer_lost
            if callback is not None:
                for peer in expired:
                    try:
                        callback(peer)
                    except Exception:
                        pass

    # -- 查询 -------------------------------------------------------------

    def peers(self) -> List[PeerInfo]:
        with self._lock:
            values = list(self._peers.values())
        return sorted(values, key=lambda peer: (peer.name.lower(), peer.id))

    def find(self, token: str) -> Optional[PeerInfo]:
        """按设备 ID / 完整名字 / 唯一子串查找。"""
        if not token:
            return None
        token = token.strip()
        peers = self.peers()
        for peer in peers:
            if peer.id == token:
                return peer
        for peer in peers:
            if peer.name == token:
                return peer
        lowered = token.lower()
        matches = [peer for peer in peers if lowered in peer.name.lower() or token in peer.id]
        if len(matches) == 1:
            return matches[0]
        return None


# ---------------------------------------------------------------------------
# 参考对端（接收方 + 发现），spec 4.3 / 5 / 6
# ---------------------------------------------------------------------------


class SaveFileError(Exception):
    """接收文件失败（半截文件会被清理）。"""


class ReferencePeer:
    """电脑端参考实现：UDP 发现 + TCP 接收端。"""

    def __init__(
        self,
        name: str = "Python 参考对端",
        device_id: Optional[str] = None,
        pairing_code: Optional[str] = None,
        receive_dir: Optional[os.PathLike] = None,
        state_path: Optional[os.PathLike] = None,
        enable_discovery: bool = True,
        discovery_port: int = DISCOVERY_PORT,
        bind_host: str = "0.0.0.0",
        broadcast: bool = True,
        unicast_targets: Sequence[str] = (),
        announce_interval: float = DEFAULT_ANNOUNCE_INTERVAL,
        offline_after: float = DEFAULT_OFFLINE_AFTER,
        prune_interval: float = DEFAULT_PRUNE_INTERVAL,
        tcp_port: int = 0,
        on_peer: Optional[Callable[[PeerInfo, bool], None]] = None,
        on_peer_lost: Optional[Callable[[PeerInfo], None]] = None,
        on_text: Optional[Callable[[dict], None]] = None,
        on_file: Optional[Callable[[dict], None]] = None,
        on_pair_request: Optional[Callable[[dict], None]] = None,
        on_pair_success: Optional[Callable[[dict], None]] = None,
        logger: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.device_name = name
        self.state_path = Path(state_path) if state_path else None
        state = load_state(self.state_path)
        self.device_id = device_id or state.get("id") or make_device_id()
        paired_state = state.get("paired", [])
        self._paired = set(item for item in paired_state if isinstance(item, str))
        if pairing_code is None:
            self.pairing_code = make_pairing_code()
        else:
            normalized = normalize_pairing_code(pairing_code)
            if normalized is None:
                raise ValueError("配对码必须是 6 位数字：%r" % (pairing_code,))
            self.pairing_code = normalized
        self.receive_dir = Path(receive_dir) if receive_dir else DEFAULT_RECEIVE_DIR
        self.enable_discovery = enable_discovery
        self.discovery_port = discovery_port
        self.bind_host = bind_host
        self.broadcast = broadcast
        self.unicast_targets = tuple(unicast_targets)
        self.announce_interval = announce_interval
        self.offline_after = offline_after
        self.prune_interval = prune_interval
        self._requested_tcp_port = int(tcp_port)

        self.on_peer = on_peer
        self.on_peer_lost = on_peer_lost
        self.on_text = on_text
        self.on_file = on_file
        self.on_pair_request = on_pair_request
        self.on_pair_success = on_pair_success
        self.log = logger or (lambda message: None)

        self.discovery: Optional[DiscoveryService] = None
        self.port = 0
        self.connection_count = 0
        self.messages: List[dict] = []
        self._pending_pairs: Dict[str, str] = {}
        self._clients: set = set()
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._listen: Optional[socket.socket] = None
        self._accept_thread: Optional[threading.Thread] = None
        self._started = False

    # -- 生命周期 ---------------------------------------------------------

    def start(self) -> "ReferencePeer":
        if self._started:
            return self
        listen_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listen_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listen_sock.bind(("0.0.0.0", self._requested_tcp_port))
        except OSError as exc:
            listen_sock.close()
            raise RuntimeError("TCP 监听失败：%s" % exc) from exc
        listen_sock.listen(8)
        listen_sock.settimeout(0.25)
        self._listen = listen_sock
        self.port = listen_sock.getsockname()[1]
        self.receive_dir.mkdir(parents=True, exist_ok=True)

        if self.enable_discovery:
            self.discovery = DiscoveryService(
                device_id=self.device_id,
                device_name=self.device_name,
                tcp_port=self.port,
                discovery_port=self.discovery_port,
                bind_host=self.bind_host,
                broadcast=self.broadcast,
                unicast_targets=self.unicast_targets,
                announce_interval=self.announce_interval,
                offline_after=self.offline_after,
                prune_interval=self.prune_interval,
                on_peer=self.on_peer,
                on_peer_lost=self.on_peer_lost,
            )
            try:
                self.discovery.start()
            except Exception:
                self.discovery = None
                try:
                    listen_sock.close()
                except OSError:
                    pass
                self._listen = None
                raise

        self._started = True
        self._accept_thread = threading.Thread(target=self._accept_loop, name="reference-peer-accept", daemon=True)
        self._accept_thread.start()
        if self.state_path is not None:
            save_state(
                self.state_path,
                {
                    "id": self.device_id,
                    "name": self.device_name,
                    "paired": self.paired_ids(),
                    "updatedAt": int(time.time()),
                },
            )
        self.log("参考对端已启动 name=%s code=%s tcp=%d" % (self.device_name, self.pairing_code, self.port))
        return self

    def stop(self) -> None:
        self._stop.set()
        if self.discovery is not None:
            self.discovery.stop()
            self.discovery = None
        if self._listen is not None:
            try:
                self._listen.close()
            except OSError:
                pass
            self._listen = None
        with self._lock:
            clients = list(self._clients)
        for conn in clients:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass
        with self._lock:
            self._clients.clear()
        if self._accept_thread is not None and self._accept_thread.is_alive():
            self._accept_thread.join(1.0)
        self._started = False

    # -- 配对状态 ---------------------------------------------------------

    def paired_ids(self) -> List[str]:
        with self._lock:
            return sorted(self._paired)

    def is_paired(self, peer_id: str) -> bool:
        with self._lock:
            return peer_id in self._paired

    def pending_pair_names(self) -> Dict[str, str]:
        with self._lock:
            return dict(self._pending_pairs)

    def _remember_paired(self, peer_id: str) -> None:
        with self._lock:
            self._paired.add(peer_id)
        save_state(
            self.state_path,
            {
                "id": self.device_id,
                "name": self.device_name,
                "paired": self.paired_ids(),
                "updatedAt": int(time.time()),
            },
        )

    # -- 接收 -------------------------------------------------------------

    def _accept_loop(self) -> None:
        assert self._listen is not None
        while not self._stop.is_set():
            try:
                conn, addr = self._listen.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with self._lock:
                self.connection_count += 1
                self._clients.add(conn)
            conn.settimeout(IO_TIMEOUT_SECONDS)
            threading.Thread(
                target=self._handle_client_guarded,
                args=(conn, addr),
                name="reference-peer-client",
                daemon=True,
            ).start()

    def _handle_client_guarded(self, conn: socket.socket, addr: Tuple[str, int]) -> None:
        try:
            self._handle_client(conn, addr)
        except (ConnectionClosed, ProtocolError, OSError):
            pass
        except Exception as exc:  # 单条连接异常不影响监听
            self.log("处理连接异常：%r" % (exc,))
        finally:
            with self._lock:
                self._clients.discard(conn)
            try:
                conn.close()
            except OSError:
                pass

    def _handle_client(self, conn: socket.socket, addr: Tuple[str, int]) -> None:
        try:
            hello = read_frame(conn)
        except InvalidMessage:
            # spec 4.3：不是合法 JSON 对象时，能回就回 error 再关闭。
            write_frame_best_effort(conn, {"type": "error", "message": HELLO_ERROR_MESSAGE})
            return
        except (ConnectionClosed, ProtocolError, OSError):
            return

        peer_id = hello.get("id")
        peer_name = hello.get("name")
        valid = (
            hello.get("app") == APP_TAG
            and isinstance(peer_id, str)
            and peer_id.strip() != ""
            and peer_id != self.device_id
            and isinstance(peer_name, str)
            and peer_name.strip() != ""
        )
        if not valid:
            write_frame_best_effort(conn, {"type": "error", "message": HELLO_ERROR_MESSAGE})
            return

        assert isinstance(peer_id, str) and isinstance(peer_name, str)
        with self._lock:
            already_paired = peer_id in self._paired
        if not already_paired:
            code = normalize_pairing_code(hello.get("code"))
            if code is None or code != self.pairing_code:
                with self._lock:
                    self._pending_pairs[peer_id] = peer_name
                self._emit_pair_request(peer_id, peer_name)
                write_frame_best_effort(conn, {"type": "pair_required", "name": self.device_name})
                return
            self._remember_paired(peer_id)
            self._emit_pair_success(peer_id, peer_name)

        write_frame(conn, {"type": "hello_ok", "name": self.device_name, "id": self.device_id})

        while True:
            try:
                frame = read_frame(conn)
            except (ConnectionClosed, ProtocolError, OSError):
                return
            frame_type = frame.get("type")
            if frame_type == "text":
                text = frame.get("text")
                if not isinstance(text, str):
                    return
                message = {
                    "kind": "text",
                    "direction": "incoming",
                    "peerId": peer_id,
                    "peerName": peer_name,
                    "text": text,
                    "time": now_seconds(),
                }
                with self._lock:
                    self.messages.append(message)
                self._emit_text(message)
                write_frame(conn, {"type": "ok"})
            elif frame_type == "file":
                name = frame.get("name")
                size = frame.get("size")
                if not isinstance(name, str) or isinstance(size, bool) or not isinstance(size, int) or size < 0:
                    return
                try:
                    saved = self._receive_file(conn, name, size)
                except SaveFileError as exc:
                    self.log("接收文件失败：%s" % exc)
                    write_frame_best_effort(conn, {"type": "error", "message": SAVE_FAILED_MESSAGE})
                    return
                message = {
                    "kind": "file",
                    "direction": "incoming",
                    "peerId": peer_id,
                    "peerName": peer_name,
                    "originalName": name,
                    "savedName": saved["savedName"],
                    "savedPath": saved["savedPath"],
                    "size": size,
                    "sha256": saved["sha256"],
                    "time": now_seconds(),
                }
                with self._lock:
                    self.messages.append(message)
                self._emit_file(message)
                write_frame(conn, {"type": "ok"})
            elif frame_type == "bye":
                return
            else:
                return

    def _receive_file(self, conn: socket.socket, name: str, size: int) -> dict:
        safe_name = sanitize_file_name(name)
        if safe_name is None:
            raise SaveFileError("非法文件名：%r" % (name,))
        try:
            self.receive_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise SaveFileError("创建接收目录失败：%s" % exc)
        path, saved_name = allocate_receive_path(self.receive_dir, safe_name)
        digest = hashlib.sha256()
        remaining = size
        try:
            with open(path, "wb") as handle:
                while remaining > 0:
                    chunk = read_exact(conn, min(FILE_CHUNK_BYTES, remaining))
                    handle.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
        except (ProtocolError, OSError, ValueError) as exc:
            try:
                path.unlink()
            except OSError:
                pass
            raise SaveFileError("保存失败：%s" % exc)
        return {"savedPath": str(path), "savedName": saved_name, "sha256": digest.hexdigest()}

    # -- 回调 -------------------------------------------------------------

    def _emit_text(self, message: dict) -> None:
        if self.on_text is not None:
            try:
                self.on_text(message)
            except Exception:
                pass

    def _emit_file(self, message: dict) -> None:
        if self.on_file is not None:
            try:
                self.on_file(message)
            except Exception:
                pass

    def _emit_pair_request(self, peer_id: str, peer_name: str) -> None:
        if self.on_pair_request is not None:
            try:
                self.on_pair_request({"peerId": peer_id, "peerName": peer_name})
            except Exception:
                pass

    def _emit_pair_success(self, peer_id: str, peer_name: str) -> None:
        if self.on_pair_success is not None:
            try:
                self.on_pair_success({"peerId": peer_id, "peerName": peer_name})
            except Exception:
                pass

    # -- 查询 -------------------------------------------------------------

    @property
    def active_connections(self) -> int:
        """当前仍在处理的 TCP 连接数（测试/诊断用）。"""
        with self._lock:
            return len(self._clients)

    def received_texts(self) -> List[dict]:
        with self._lock:
            return [item for item in self.messages if item["kind"] == "text"]

    def received_files(self) -> List[dict]:
        with self._lock:
            return [item for item in self.messages if item["kind"] == "file"]

    def wait_for_peer(self, token: str, timeout: float) -> Optional[PeerInfo]:
        if self.discovery is None:
            return None
        return wait_until(lambda: self.discovery.find(token), timeout)


# ---------------------------------------------------------------------------
# 发送方（client -> server），spec 4.2 / 4.4 / 5 / 6
# ---------------------------------------------------------------------------


@dataclass
class SendResult:
    kind: str
    message: str
    peer_name: str = ""
    peer_id: str = ""
    response: dict = field(default_factory=dict)
    connection_made: bool = True

    @property
    def ok(self) -> bool:
        return self.kind == "ok"


def connect_to(host: str, port: int, connect_timeout: float = CONNECT_TIMEOUT_SECONDS) -> socket.socket:
    conn = socket.create_connection((host, port), timeout=connect_timeout)
    conn.settimeout(IO_TIMEOUT_SECONDS)
    return conn


def handshake(
    conn: socket.socket,
    device_id: str,
    device_name: str,
    code: Optional[str],
    peer_name_hint: str = "",
) -> SendResult:
    hello = {
        "app": APP_TAG,
        "v": PROTOCOL_VERSION,
        "id": device_id,
        "name": device_name,
    }
    if code is not None and str(code).strip():
        hello["code"] = str(code).strip()
    try:
        write_frame(conn, hello)
        response = read_frame(conn)
    except (ConnectionClosed, ProtocolError, OSError):
        return SendResult("no_response", NO_RESPONSE_MESSAGE, peer_name=peer_name_hint)
    response_type = response.get("type")
    if response_type == "hello_ok":
        return SendResult(
            "ok",
            "握手成功",
            peer_name=str(response.get("name") or peer_name_hint),
            peer_id=str(response.get("id") or ""),
            response=response,
        )
    if response_type == "pair_required":
        name = str(response.get("name") or peer_name_hint or "对方")
        return SendResult(
            "need_pair",
            "首次给「%s」发送，需要输入对方屏幕上显示的 6 位配对码" % name,
            peer_name=name,
            response=response,
        )
    if response_type == "error":
        return SendResult(
            "error",
            str(response.get("message") or "对方拒绝了连接"),
            peer_name=peer_name_hint,
            response=response,
        )
    return SendResult("protocol_mismatch", PROTOCOL_MISMATCH_MESSAGE, peer_name=peer_name_hint, response=response)


def connect_failure(host: str, peer_name: str) -> SendResult:
    label = peer_name or host
    return SendResult(
        "connect_failed",
        "连不上「%s」，请确认两台设备在同一局域网、对方应用已打开" % label,
        peer_name=peer_name,
        connection_made=False,
    )


def send_text(
    host: str,
    port: int,
    text: str,
    device_id: str,
    device_name: str,
    code: Optional[str] = None,
    peer_name: str = "",
) -> SendResult:
    """发一条文字：新建 TCP -> hello -> text -> 等 ok -> bye。"""
    if not isinstance(text, str) or not text.strip():
        return SendResult("empty_text", EMPTY_TEXT_MESSAGE, peer_name=peer_name, connection_made=False)
    try:
        conn = connect_to(host, int(port))
    except OSError:
        return connect_failure(host, peer_name)
    try:
        result = handshake(conn, device_id, device_name, code, peer_name)
        if not result.ok:
            return result
        try:
            write_frame(conn, {"type": "text", "text": text})
            ack = read_frame(conn)
        except (ConnectionClosed, ProtocolError, OSError):
            return SendResult("no_ack", TEXT_NOT_ACKED_MESSAGE, peer_name=result.peer_name, peer_id=result.peer_id)
        if ack.get("type") != "ok":
            return SendResult("no_ack", TEXT_NOT_ACKED_MESSAGE, peer_name=result.peer_name, peer_id=result.peer_id)
        try:
            write_frame(conn, {"type": "bye"})
        except OSError:
            pass
        return SendResult(
            "ok",
            "已把文字发送给 %s" % result.peer_name,
            peer_name=result.peer_name,
            peer_id=result.peer_id,
            response=ack,
        )
    finally:
        try:
            conn.close()
        except OSError:
            pass


def send_file(
    host: str,
    port: int,
    file_path: os.PathLike,
    device_id: str,
    device_name: str,
    code: Optional[str] = None,
    peer_name: str = "",
    file_name: Optional[str] = None,
) -> SendResult:
    """发一个文件：新建 TCP -> hello -> file 头 -> 原始字节（256 KiB 分块）-> 等 ok -> bye。"""
    path = Path(file_path)
    name = file_name or path.name
    try:
        size = path.stat().st_size
    except OSError:
        return SendResult("bad_file", "读不到文件：%s" % name, peer_name=peer_name, connection_made=False)
    if size <= 0:
        return SendResult("bad_file", "读不到文件：%s" % name, peer_name=peer_name, connection_made=False)
    try:
        conn = connect_to(host, int(port))
    except OSError:
        return connect_failure(host, peer_name)
    try:
        result = handshake(conn, device_id, device_name, code, peer_name)
        if not result.ok:
            return result
        try:
            write_frame(conn, {"type": "file", "name": name, "size": size})
            with open(path, "rb") as handle:
                while True:
                    chunk = handle.read(FILE_CHUNK_BYTES)
                    if not chunk:
                        break
                    conn.sendall(chunk)
            ack = read_frame(conn)
        except (ConnectionClosed, ProtocolError, OSError):
            return SendResult("no_ack", FILE_NOT_ACKED_MESSAGE, peer_name=result.peer_name, peer_id=result.peer_id)
        if ack.get("type") != "ok":
            return SendResult("no_ack", FILE_NOT_ACKED_MESSAGE, peer_name=result.peer_name, peer_id=result.peer_id)
        try:
            write_frame(conn, {"type": "bye"})
        except OSError:
            pass
        return SendResult(
            "ok",
            "已把「%s」发送给 %s" % (name, result.peer_name),
            peer_name=result.peer_name,
            peer_id=result.peer_id,
            response=ack,
        )
    finally:
        try:
            conn.close()
        except OSError:
            pass


def pair_only(
    host: str,
    port: int,
    code: str,
    device_id: str,
    device_name: str,
    peer_name: str = "",
) -> SendResult:
    """只握手配对，不发内容；成功后发 bye。"""
    normalized = normalize_pairing_code(code)
    if normalized is None:
        return SendResult("bad_code", BAD_PAIR_CODE_MESSAGE, peer_name=peer_name, connection_made=False)
    try:
        conn = connect_to(host, int(port))
    except OSError:
        return connect_failure(host, peer_name)
    try:
        result = handshake(conn, device_id, device_name, normalized, peer_name)
        if result.kind == "ok":
            try:
                write_frame(conn, {"type": "bye"})
            except OSError:
                pass
            return SendResult(
                "ok",
                "已与「%s」配对，可以直接发送文字和文件" % result.peer_name,
                peer_name=result.peer_name,
                peer_id=result.peer_id,
                response=result.response,
            )
        if result.kind == "need_pair":
            return SendResult(
                "need_pair",
                WRONG_CODE_MESSAGE,
                peer_name=result.peer_name,
                response=result.response,
            )
        return result
    finally:
        try:
            conn.close()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def print_result(result: SendResult) -> None:
    peer = " peer=%s" % json_value(result.peer_name) if result.peer_name else ""
    print(
        "RESULT kind=%s message=%s%s" % (result.kind, json_value(result.message), peer),
        flush=True,
    )


def result_exit_code(result: SendResult) -> int:
    if result.ok:
        return EXIT_OK
    if result.kind == "need_pair":
        return EXIT_NEED_PAIR
    return EXIT_FAIL


def load_identity(state_path: Optional[Path], explicit_id: Optional[str]) -> Tuple[str, set]:
    state = load_state(state_path)
    device_id = explicit_id or state.get("id") or make_device_id()
    paired = set(item for item in state.get("paired", []) if isinstance(item, str))
    return device_id, paired


def save_identity(state_path: Optional[Path], device_id: str, name: str, paired: set) -> None:
    save_state(
        state_path,
        {"id": device_id, "name": name, "paired": sorted(paired), "updatedAt": int(time.time())},
    )


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
    """允许把 --name/--id/--state/--verbose 写在子命令后面（argparse 默认只认子命令前）。

    用 SUPPRESS 作为默认值，避免子命令里没写时覆盖掉顶层已解析的值。
    """
    parser.add_argument("--name", default=argparse.SUPPRESS, help="本机设备名")
    parser.add_argument("--id", default=argparse.SUPPRESS, help="本机设备 ID")
    parser.add_argument("--state", default=argparse.SUPPRESS, help="身份/配对状态文件")
    parser.add_argument("--verbose", action="store_true", default=argparse.SUPPRESS, help="打印内部日志")


def add_target_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--host", default=None, help="对端 IP（与 --port 一起用时跳过发现）")
    parser.add_argument("--port", type=int, default=None, help="对端 TCP 端口（随 UDP 通告，或手动指定）")
    parser.add_argument("--peer", default=None, help="按发现的设备名/ID 查找目标（如「iPhone 17」）")
    parser.add_argument(
        "--discovery-seconds", type=float, default=6.0, help="--peer 时等待发现的最长秒数（默认 6）"
    )
    parser.add_argument(
        "--discovery-port", type=int, default=DISCOVERY_PORT, help="发现端口（默认 52730，联调时不要改）"
    )
    parser.add_argument("--timeout", type=float, default=IO_TIMEOUT_SECONDS, help="握手/读写超时秒数（默认 30）")


def resolve_target(args: argparse.Namespace, own_id: str) -> Tuple[str, int]:
    if args.host and args.port:
        return str(args.host), int(args.port)
    if not args.peer:
        raise RuntimeError("需要 --host/--port，或用 --peer 指定已发现的设备名/ID")
    service = DiscoveryService(
        device_id=own_id,
        device_name="Python 目标解析",
        tcp_port=0,
        discovery_port=int(args.discovery_port),
        bind_host="0.0.0.0",
        broadcast=False,
    )
    try:
        service.start()
    except DiscoveryError as exc:
        raise RuntimeError(str(exc))
    try:
        print(
            "DISCOVERING peer=%s seconds=%s" % (json_value(args.peer), args.discovery_seconds),
            flush=True,
        )
        peer = wait_until(lambda: service.find(args.peer), float(args.discovery_seconds))
    finally:
        service.stop()
    if peer is None:
        raise RuntimeError(
            "在 %s 秒内没有发现「%s」；确认两端在同一 Wi-Fi、对方 App 在前台、"
            "必要时用 --host/--port 直连（端口见对方侧或 UDP 通告）"
            % (args.discovery_seconds, args.peer)
        )
    print(
        "TARGET id=%s name=%s host=%s port=%d" % (peer.id, json_value(peer.name), peer.host, peer.port),
        flush=True,
    )
    return peer.host, peer.port


def run_serve(args: argparse.Namespace) -> int:
    state_path = Path(args.state) if args.state else default_state_path(args.name)
    peer = ReferencePeer(
        name=args.name,
        device_id=args.id,
        pairing_code=args.code,
        receive_dir=args.receive_dir or str(DEFAULT_RECEIVE_DIR),
        state_path=state_path,
        discovery_port=int(args.discovery_port),
        broadcast=not args.no_broadcast,
        unicast_targets=tuple(args.unicast_to or ()),
        logger=(lambda message: print("LOG %s" % message, flush=True)) if args.verbose else None,
    )

    def emit(event: dict) -> None:
        print("EVENT " + json.dumps(event, ensure_ascii=False), flush=True)

    peer.on_peer = lambda info, is_new: emit(
        {
            "event": "peer_online",
            "new": is_new,
            "id": info.id,
            "name": info.name,
            "host": info.host,
            "port": info.port,
            "v": info.version,
        }
    )
    peer.on_peer_lost = lambda info: emit({"event": "peer_offline", "id": info.id, "name": info.name})
    peer.on_pair_request = lambda info: emit(
        {"event": "pair_request", "id": info["peerId"], "name": info["peerName"]}
    )
    peer.on_pair_success = lambda info: emit(
        {"event": "pair_ok", "id": info["peerId"], "name": info["peerName"]}
    )
    peer.on_text = lambda message: emit(
        {
            "event": "text",
            "peerId": message["peerId"],
            "peerName": message["peerName"],
            "text": message["text"],
        }
    )
    peer.on_file = lambda message: emit(
        {
            "event": "file",
            "peerId": message["peerId"],
            "peerName": message["peerName"],
            "originalName": message["originalName"],
            "savedName": message["savedName"],
            "savedPath": message["savedPath"],
            "size": message["size"],
            "sha256": message["sha256"],
        }
    )

    try:
        peer.start()
    except (DiscoveryError, RuntimeError) as exc:
        print("ERROR %s" % exc, flush=True)
        return EXIT_FAIL

    print(
        "READY device=%s name=%s code=%s tcp=%d receive=%s state=%s"
        % (
            peer.device_id,
            json_value(peer.device_name),
            peer.pairing_code,
            peer.port,
            json_value(str(peer.receive_dir)),
            json_value(str(state_path)),
        ),
        flush=True,
    )
    print("HINT 让手机端发现「%s」，首次发送时输入配对码 %s" % (peer.device_name, peer.pairing_code), flush=True)

    stopping = threading.Event()

    def handle_signal(signum, frame):  # noqa: ARG001
        stopping.set()

    previous_term = signal.signal(signal.SIGTERM, handle_signal)
    try:
        deadline = time.monotonic() + args.seconds if args.seconds and args.seconds > 0 else None
        while not stopping.is_set():
            if deadline is not None and time.monotonic() >= deadline:
                break
            time.sleep(0.15)
    except KeyboardInterrupt:
        pass
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        peer.stop()
    print("STOPPED", flush=True)
    return EXIT_OK


def run_discover(args: argparse.Namespace) -> int:
    own_id = args.id or make_device_id()
    service = DiscoveryService(
        device_id=own_id,
        device_name="Python 发现端",
        tcp_port=0,
        discovery_port=int(args.discovery_port),
        bind_host="0.0.0.0",
        broadcast=False,
    )

    def emit_discovered(peer: PeerInfo, is_new: bool) -> None:
        if not is_new:
            return
        print(
            "DISCOVERED id=%s name=%s host=%s port=%d v=%d"
            % (peer.id, json_value(peer.name), peer.host, peer.port, peer.version),
            flush=True,
        )

    def emit_gone(peer: PeerInfo) -> None:
        print("GONE id=%s name=%s" % (peer.id, json_value(peer.name)), flush=True)

    service.on_peer = emit_discovered
    service.on_peer_lost = emit_gone

    try:
        service.start()
    except DiscoveryError as exc:
        print("ERROR %s" % exc, flush=True)
        return EXIT_FAIL
    print("LISTEN udp_port=%d seconds=%s" % (service.discovery_port, args.seconds), flush=True)
    try:
        deadline = time.monotonic() + args.seconds if args.seconds and args.seconds > 0 else None
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                break
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        peers = service.peers()
        service.stop()
    print("DONE peers=%d" % len(peers), flush=True)
    return EXIT_OK


def run_pair(args: argparse.Namespace) -> int:
    state_path = Path(args.state) if args.state else default_state_path(args.name)
    device_id, paired = load_identity(state_path, args.id)
    save_identity(state_path, device_id, args.name, paired)
    try:
        host, port = resolve_target(args, device_id)
    except RuntimeError as exc:
        print("ERROR %s" % exc, flush=True)
        return EXIT_FAIL
    result = pair_only(
        host,
        port,
        args.code,
        device_id=device_id,
        device_name=args.name,
        peer_name=getattr(args, "peer", "") or "",
    )
    print_result(result)
    if result.ok and result.peer_id:
        paired.add(result.peer_id)
        save_identity(state_path, device_id, args.name, paired)
    return result_exit_code(result)


def run_send_text(args: argparse.Namespace) -> int:
    state_path = Path(args.state) if args.state else default_state_path(args.name)
    device_id, paired = load_identity(state_path, args.id)
    save_identity(state_path, device_id, args.name, paired)
    text = args.text
    if text == "-":
        text = sys.stdin.read()
    try:
        host, port = resolve_target(args, device_id)
    except RuntimeError as exc:
        print("ERROR %s" % exc, flush=True)
        return EXIT_FAIL
    result = send_text(
        host,
        port,
        text,
        device_id=device_id,
        device_name=args.name,
        code=args.code,
        peer_name=getattr(args, "peer", "") or "",
    )
    print_result(result)
    if result.ok and result.peer_id:
        paired.add(result.peer_id)
        save_identity(state_path, device_id, args.name, paired)
    return result_exit_code(result)


def run_send_file(args: argparse.Namespace) -> int:
    state_path = Path(args.state) if args.state else default_state_path(args.name)
    device_id, paired = load_identity(state_path, args.id)
    save_identity(state_path, device_id, args.name, paired)
    try:
        host, port = resolve_target(args, device_id)
    except RuntimeError as exc:
        print("ERROR %s" % exc, flush=True)
        return EXIT_FAIL
    result = send_file(
        host,
        port,
        args.file,
        device_id=device_id,
        device_name=args.name,
        code=args.code,
        peer_name=getattr(args, "peer", "") or "",
        file_name=args.file_name,
    )
    print_result(result)
    if result.ok and result.peer_id:
        paired.add(result.peer_id)
        save_identity(state_path, device_id, args.name, paired)
    return result_exit_code(result)


def run_info(args: argparse.Namespace) -> int:
    state_path = Path(args.state) if args.state else default_state_path(args.name)
    state = load_state(state_path)
    device_id = args.id or state.get("id") or "(尚未生成，首次 serve/send 时创建)"
    paired = [item for item in state.get("paired", []) if isinstance(item, str)]
    print("DEVICE id=%s name=%s" % (device_id, json_value(args.name)), flush=True)
    print("STATE path=%s exists=%s" % (json_value(str(state_path)), state_path.exists()), flush=True)
    print("PAIRED count=%d ids=%s" % (len(paired), json_value(paired)), flush=True)
    print("RECEIVE default=%s" % json_value(str(DEFAULT_RECEIVE_DIR)), flush=True)
    print("DISCOVERY_PORT %d" % DISCOVERY_PORT, flush=True)
    print("TCP FRAME 4-byte big-endian length + UTF-8 JSON，上限 %d 字节" % MAX_FRAME_BYTES, flush=True)
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="reference_peer.py",
        description="文件互传助手移动端协议参考对端（docs/LAN-transfer-spec.md）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--name", default="Python 参考对端", help="本机设备名（默认「Python 参考对端」）")
    parser.add_argument("--id", default=None, help="本机设备 ID（默认持久化到 --state，首次随机生成）")
    parser.add_argument(
        "--state", default=None, help="身份/配对状态文件；默认 mobile/tests/.state/<name>.json"
    )
    parser.add_argument("--verbose", action="store_true", help="打印内部日志")

    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    serve = sub.add_parser("serve", help="作为电脑端常驻：发现 + 接收文字/文件")
    add_common_arguments(serve)
    serve.add_argument("--code", default=None, help="固定 6 位配对码（默认随机）")
    serve.add_argument("--receive-dir", default=None, help="接收目录（默认 mobile/tests/received）")
    serve.add_argument("--seconds", type=float, default=0, help="运行秒数；0 表示一直运行（Ctrl-C 退出）")
    serve.add_argument("--discovery-port", type=int, default=DISCOVERY_PORT, help="UDP 发现端口（默认 52730）")
    serve.add_argument("--no-broadcast", action="store_true", help="不广播（只监听，适合隔离环境）")
    serve.add_argument(
        "--unicast-to",
        action="append",
        default=[],
        metavar="HOST",
        help="额外向这些 IP 单播心跳（可重复，对应 macOS 端的已知设备心跳）",
    )
    serve.set_defaults(func=run_serve)

    discover = sub.add_parser("discover", help="监听 UDP 52730 并列出设备")
    add_common_arguments(discover)
    discover.add_argument("--seconds", type=float, default=5.0, help="监听秒数（默认 5）")
    discover.add_argument("--discovery-port", type=int, default=DISCOVERY_PORT, help="UDP 发现端口（默认 52730）")
    discover.set_defaults(func=run_discover)

    pair = sub.add_parser("pair", help="只握手配对，不发内容")
    add_common_arguments(pair)
    add_target_arguments(pair)
    pair.add_argument("--code", required=True, help="对端屏幕上显示的 6 位配对码")
    pair.set_defaults(func=run_pair)

    send_text_parser = sub.add_parser("send-text", help="发送一段文字")
    add_common_arguments(send_text_parser)
    add_target_arguments(send_text_parser)
    send_text_parser.add_argument("--text", required=True, help="文字内容（可含中文/emoji；'-' 表示读 stdin）")
    send_text_parser.add_argument("--code", default=None, help="首次配对时对端的 6 位配对码")
    send_text_parser.set_defaults(func=run_send_text)

    send_file_parser = sub.add_parser("send-file", help="发送一个文件")
    add_common_arguments(send_file_parser)
    add_target_arguments(send_file_parser)
    send_file_parser.add_argument("--file", required=True, help="本地文件路径")
    send_file_parser.add_argument("--file-name", default=None, help="覆盖发送给对端的文件名（默认取 basename）")
    send_file_parser.add_argument("--code", default=None, help="首次配对时对端的 6 位配对码")
    send_file_parser.set_defaults(func=run_send_file)

    info = sub.add_parser("info", help="打印本机身份与配对状态")
    add_common_arguments(info)
    info.set_defaults(func=run_info)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        return EXIT_OK
    except BrokenPipeError:
        return EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
