#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""交互式「电脑端」模拟器：在手机端 App 面前扮演 macOS/Windows 端。

启动后会：
- 用 UDP 52730 广播并被手机 App 发现；
- 打印本机 6 位配对码与 TCP 端口，接受手机 App 的配对 / 文字 / 文件；
- 可以主动列出发现的手机、配对、发送文字 / 文件、查看已收到的内容。

两种用法：

1) 手动交互（像使用电脑端 App 一样）：

       python3 mobile/tests/run_reference_peer.py --name "QA 电脑"

   然后输入 help 看命令。

2) 脚本化（供自动化/CI 使用）：

       python3 mobile/tests/run_reference_peer.py --script /tmp/commands.txt

   脚本每一行一条命令，空行和 # 开头为注释；出错默认继续，--fail-fast 时立即退出。
   适合在没有真机时先用两个 Python 对端验证协议，再换成手机 App 手工复测。

常用命令：
    help                         显示帮助
    list / devices               列出发现的设备
    code                         打印本机配对码
    info / status                本机身份、端口、已配对数量、收发统计
    wait <秒>                    等待一段时间（期间照常打印事件）
    wait-peer <名字|ID> [超时]    等待某台设备出现
    pair <名字|ID> <配对码>       主动与对方配对（不发内容）
    send-text <名字|ID> <文字>    向对方发送文字（需已配对）
    send-file <名字|ID> <路径>    向对方发送文件（需已配对）
    received [条数]              打印已收到的文字/文件
    quit / exit                  退出

说明：本工具只写 mobile/tests/ 下的默认状态和接收目录，不依赖 App；协议以
docs/LAN-transfer-spec.md 为准。
"""

from __future__ import annotations

import argparse
import json
import shlex
import sys
import time
from pathlib import Path

import reference_peer as rp


class CommandError(Exception):
    """命令执行失败（打印 ERROR 后继续）。"""


class Simulator:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.state_path = Path(args.state) if args.state else rp.default_state_path(args.name)
        self.peer = rp.ReferencePeer(
            name=args.name,
            device_id=args.id,
            pairing_code=args.code,
            receive_dir=args.receive_dir or str(rp.DEFAULT_RECEIVE_DIR),
            state_path=self.state_path,
            discovery_port=int(args.discovery_port),
            broadcast=not args.no_broadcast,
            logger=(lambda message: print("LOG %s" % message, flush=True)) if args.verbose else None,
        )
        self.errors = 0
        self.outbound_paired = set()
        self.started_at = time.monotonic()
        self.deadline = (
            time.monotonic() + args.seconds if args.seconds and args.seconds > 0 else None
        )
        self._bind_events()

    # -- 事件输出 ---------------------------------------------------------

    def emit(self, event: dict) -> None:
        print("EVENT " + json.dumps(event, ensure_ascii=False), flush=True)

    def _bind_events(self) -> None:
        peer = self.peer
        peer.on_peer = lambda info, is_new: self.emit(
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
        peer.on_peer_lost = lambda info: self.emit(
            {"event": "peer_offline", "id": info.id, "name": info.name}
        )
        peer.on_pair_request = lambda info: self.emit(
            {"event": "pair_request", "id": info["peerId"], "name": info["peerName"]}
        )
        peer.on_pair_success = lambda info: self.emit(
            {"event": "pair_ok", "id": info["peerId"], "name": info["peerName"]}
        )
        peer.on_text = lambda message: self.emit(
            {
                "event": "text",
                "peerId": message["peerId"],
                "peerName": message["peerName"],
                "text": message["text"],
            }
        )
        peer.on_file = lambda message: self.emit(
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

    # -- 启动 / 停止 ------------------------------------------------------

    def start(self) -> None:
        self.peer.start()
        print(
            "READY device=%s name=%s code=%s tcp=%d receive=%s state=%s"
            % (
                self.peer.device_id,
                rp.json_value(self.peer.device_name),
                self.peer.pairing_code,
                self.peer.port,
                rp.json_value(str(self.peer.receive_dir)),
                rp.json_value(str(self.state_path)),
            ),
            flush=True,
        )
        print(
            "HINT 让手机 App 发现「%s」；首次发送时在手机上输入配对码 %s"
            % (self.peer.device_name, self.peer.pairing_code),
            flush=True,
        )

    def stop(self) -> None:
        self.peer.stop()

    # -- 工具 -------------------------------------------------------------

    def _deadline_reached(self) -> bool:
        return self.deadline is not None and time.monotonic() >= self.deadline

    def peers(self):
        if self.peer.discovery is None:
            return []
        return self.peer.discovery.peers()

    def resolve_peer(self, token: str):
        peers = self.peers()
        if token.isdigit():
            index = int(token)
            if 1 <= index <= len(peers):
                return peers[index - 1]
            raise CommandError("没有第 %s 台设备；先运行 list 查看编号" % token)
        found = None
        if self.peer.discovery is not None:
            found = self.peer.discovery.find(token)
        if found is None:
            raise CommandError(
                "没有发现「%s」；先运行 list，或确认手机 App 已打开且在同一 Wi-Fi" % token
            )
        return found

    def describe_peer(self, peer) -> str:
        age = int(peer.age)
        return 'name=%s id=%s host=%s port=%d seen=%ds' % (
            rp.json_value(peer.name),
            peer.id,
            peer.host,
            peer.port,
            age,
        )

    # -- 命令 -------------------------------------------------------------

    def command_help(self) -> None:
        print("COMMANDS help list devices code info status wait wait-peer pair send-text send-file received quit", flush=True)
        print("EXAMPLE  pair 1 123456  /  send-text 1 你好  /  send-file 1 ./a.bin", flush=True)

    def command_list(self) -> None:
        peers = self.peers()
        if not peers:
            print("PEERS none", flush=True)
            return
        for index, peer in enumerate(peers, start=1):
            print("PEER %d %s" % (index, self.describe_peer(peer)), flush=True)
        print("PEER_COUNT %d" % len(peers), flush=True)

    def command_code(self) -> None:
        print("CODE %s" % self.peer.pairing_code, flush=True)

    def command_info(self) -> None:
        print("SELF id=%s name=%s tcp=%d code=%s" % (
            self.peer.device_id,
            rp.json_value(self.peer.device_name),
            self.peer.port,
            self.peer.pairing_code,
        ), flush=True)
        print(
            "SELF receive=%s state=%s discovery=%s"
            % (
                rp.json_value(str(self.peer.receive_dir)),
                rp.json_value(str(self.state_path)),
                "on" if self.peer.discovery is not None else "off",
            ),
            flush=True,
        )
        print(
            "STATS discovered=%d inbound_paired=%d outbound_paired=%d text=%d file=%d connections=%d"
            % (
                len(self.peers()),
                len(self.peer.paired_ids()),
                len(self.outbound_paired),
                len(self.peer.received_texts()),
                len(self.peer.received_files()),
                self.peer.connection_count,
            ),
            flush=True,
        )

    def command_wait(self, tokens) -> None:
        if len(tokens) < 2:
            raise CommandError("用法：wait <秒>")
        try:
            seconds = float(tokens[1])
        except ValueError:
            raise CommandError("秒数不是数字：%s" % tokens[1])
        print("WAIT %.1f" % seconds, flush=True)
        time.sleep(max(0.0, seconds))

    def command_wait_peer(self, tokens) -> None:
        if len(tokens) < 2:
            raise CommandError("用法：wait-peer <名字|ID> [超时秒数]")
        token = tokens[1]
        timeout = float(tokens[2]) if len(tokens) > 2 else 20.0
        print("WAITING_PEER %s timeout=%s" % (rp.json_value(token), timeout), flush=True)
        peer = self.peer.wait_for_peer(token, timeout)
        if peer is None:
            raise CommandError("在 %s 秒内没有发现「%s」" % (timeout, token))
        print("FOUND_PEER %s" % self.describe_peer(peer), flush=True)

    def command_pair(self, tokens) -> None:
        if len(tokens) < 3:
            raise CommandError("用法：pair <名字|ID|编号> <6 位配对码>")
        peer = self.resolve_peer(tokens[1])
        result = rp.pair_only(
            peer.host,
            peer.port,
            tokens[2],
            device_id=self.peer.device_id,
            device_name=self.peer.device_name,
            peer_name=peer.name,
        )
        print("PAIR kind=%s message=%s" % (result.kind, rp.json_value(result.message)), flush=True)
        if result.ok:
            self.outbound_paired.add(peer.id)
            print("PAIRED %s" % self.describe_peer(peer), flush=True)
        elif result.kind == "need_pair":
            print("HINT 配对码不对；看对方屏幕上显示的 6 位数字后重试", flush=True)

    def command_send_text(self, tokens) -> None:
        if len(tokens) < 3:
            raise CommandError("用法：send-text <名字|ID|编号> <文字>")
        peer = self.resolve_peer(tokens[1])
        text = " ".join(tokens[2:])
        result = rp.send_text(
            peer.host,
            peer.port,
            text,
            device_id=self.peer.device_id,
            device_name=self.peer.device_name,
            peer_name=peer.name,
        )
        print("SEND kind=%s message=%s" % (result.kind, rp.json_value(result.message)), flush=True)
        if result.kind == "need_pair":
            print("HINT 先用 pair %s <配对码> 配对，再重发" % tokens[1], flush=True)

    def command_send_file(self, tokens) -> None:
        if len(tokens) < 3:
            raise CommandError("用法：send-file <名字|ID|编号> <本地路径>")
        peer = self.resolve_peer(tokens[1])
        result = rp.send_file(
            peer.host,
            peer.port,
            tokens[2],
            device_id=self.peer.device_id,
            device_name=self.peer.device_name,
            peer_name=peer.name,
        )
        print("SEND kind=%s message=%s" % (result.kind, rp.json_value(result.message)), flush=True)
        if result.kind == "need_pair":
            print("HINT 先用 pair %s <配对码> 配对，再重发" % tokens[1], flush=True)

    def command_received(self, tokens) -> None:
        limit = 20
        if len(tokens) > 1:
            try:
                limit = int(tokens[1])
            except ValueError:
                raise CommandError("条数不是整数：%s" % tokens[1])
        messages = self.peer.messages[-limit:] if limit > 0 else []
        if not messages:
            print("RECEIVED none", flush=True)
            return
        for message in messages:
            if message["kind"] == "text":
                print(
                    "RECEIVED_TEXT peer=%s text=%s"
                    % (rp.json_value(message["peerName"]), rp.json_value(message["text"])),
                    flush=True,
                )
            else:
                print(
                    "RECEIVED_FILE peer=%s original=%s saved=%s size=%d sha256=%s"
                    % (
                        rp.json_value(message["peerName"]),
                        rp.json_value(message["originalName"]),
                        rp.json_value(message["savedPath"]),
                        message["size"],
                        message["sha256"],
                    ),
                    flush=True,
                )
        print(
            "RECEIVED_COUNT text=%d file=%d"
            % (len(self.peer.received_texts()), len(self.peer.received_files())),
            flush=True,
        )

    def execute(self, line: str) -> bool:
        """执行一行命令；返回 False 表示要退出。"""
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            return True
        try:
            tokens = shlex.split(stripped)
        except ValueError as exc:
            self._report_error("命令解析失败：%s" % exc)
            return True
        if not tokens:
            return True
        command = tokens[0].lower()
        try:
            if command in ("quit", "exit"):
                return False
            if command == "help":
                self.command_help()
            elif command in ("list", "devices"):
                self.command_list()
            elif command == "code":
                self.command_code()
            elif command in ("info", "status"):
                self.command_info()
            elif command == "wait":
                self.command_wait(tokens)
            elif command in ("wait-peer", "wait_peer"):
                self.command_wait_peer(tokens)
            elif command == "pair":
                self.command_pair(tokens)
            elif command in ("send-text", "send_text"):
                self.command_send_text(tokens)
            elif command in ("send-file", "send_file"):
                self.command_send_file(tokens)
            elif command == "received":
                self.command_received(tokens)
            else:
                raise CommandError("未知命令：%s（输入 help 查看）" % command)
        except CommandError as exc:
            self._report_error(str(exc))
            if self.args.fail_fast:
                return False
        except (OSError, RuntimeError) as exc:
            self._report_error("%s" % exc)
            if self.args.fail_fast:
                return False
        return True

    def _report_error(self, message: str) -> None:
        self.errors += 1
        print("ERROR " + message, flush=True)

    # -- 主循环 -----------------------------------------------------------

    def _run_script(self, script_path: str) -> None:
        path = Path(script_path)
        lines = path.read_text("utf-8").splitlines()
        for raw in lines:
            if self._deadline_reached():
                print("TIMEOUT seconds=%s" % self.args.seconds, flush=True)
                break
            if not self.execute(raw):
                break

    def _run_interactive(self) -> None:
        while True:
            try:
                line = input("> ")
            except EOFError:
                break
            if not self.execute(line):
                break

    def run(self) -> int:
        self.start()
        try:
            if self.args.script:
                self._run_script(self.args.script)
            elif not sys.stdin.isatty():
                for raw in sys.stdin:
                    if self._deadline_reached():
                        break
                    if not self.execute(raw):
                        break
            else:
                self._run_interactive()
        finally:
            self.stop()
        elapsed = time.monotonic() - self.started_at
        print("BYE elapsed=%.1fs errors=%d" % (elapsed, self.errors), flush=True)
        return 1 if self.errors else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="run_reference_peer.py",
        description="交互式/脚本化电脑端模拟器（手机 App 联调用）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--name", default="Python 电脑端", help="本机设备名（默认「Python 电脑端」）")
    parser.add_argument("--id", default=None, help="本机设备 ID（默认持久化到 --state）")
    parser.add_argument("--state", default=None, help="状态文件；默认 mobile/tests/.state/<name>.json")
    parser.add_argument("--code", default=None, help="固定 6 位配对码（默认随机）")
    parser.add_argument("--receive-dir", default=None, help="接收目录（默认 mobile/tests/received）")
    parser.add_argument("--discovery-port", type=int, default=rp.DISCOVERY_PORT, help="UDP 发现端口（默认 52730）")
    parser.add_argument("--no-broadcast", action="store_true", help="不广播（只监听）")
    parser.add_argument("--seconds", type=float, default=0, help="整个会话最长秒数；0 表示不限")
    parser.add_argument("--script", default=None, help="从文件读取命令并执行后退出")
    parser.add_argument("--fail-fast", action="store_true", help="脚本模式下遇到错误立即停止")
    parser.add_argument("--verbose", action="store_true", help="打印内部日志")
    return parser


def main(argv=None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    args = build_parser().parse_args(argv)
    simulator = Simulator(args)
    try:
        return simulator.run()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
