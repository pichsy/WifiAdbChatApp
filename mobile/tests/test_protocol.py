#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""协议级自测：用原始 socket 逐字节验证 spec，不依赖 Android/iOS App。

覆盖 docs/LAN-transfer-spec.md 的：
- TCP 帧：4 字节大端长度 + UTF-8 JSON、16 MiB 上限、循环读满（拆包）；
- 握手：hello / hello_ok / pair_required / error，6 位配对码、去空白、已配对免码；
- 内容：text / file / ok / bye，未知 type 关闭，中文 / emoji 原样；
- 文件：256 KiB 分块、0 字节接收、重名编号、路径只取最后一段、半截文件清理；
- 发现：UDP 报文字段校验、自己忽略、非法静默丢弃、8 秒超时移除、单播来源 IP。

运行：

    cd mobile/tests
    python3 -m unittest -v test_protocol.py
    # 或
    ./run_tests.sh
"""

import hashlib
import json
import os
import re
import shutil
import socket
import struct
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager

import reference_peer as rp

PAIR_CODE = "246810"
SERVER_NAME = "参考接收端"
CLIENT_ID = "raw-client-1"
CLIENT_NAME = "Python 手机端"


# ---------------------------------------------------------------------------
# 原始 socket 工具（故意不 import reference_peer 的帧函数，独立验证）
# ---------------------------------------------------------------------------


def raw_read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise AssertionError("连接提前关闭：只读到 %d/%d 字节" % (len(data), count))
        data += chunk
    return data


def raw_read_frame(sock):
    """返回 (dict, body_len)；同时校验长度头与实际正文长度一致。"""
    header = raw_read_exact(sock, 4)
    length = struct.unpack(">I", header)[0]
    body = raw_read_exact(sock, length)
    try:
        obj = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise AssertionError("响应不是合法 UTF-8 JSON：%r（%s）" % (body, exc))
    return obj, len(body)


def raw_send_frame(sock, obj):
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    sock.sendall(struct.pack(">I", len(body)) + body)
    return body


def raw_send_body(sock, body):
    sock.sendall(struct.pack(">I", len(body)) + body)


def expect_closed(sock, timeout=3.0):
    sock.settimeout(timeout)
    try:
        data = sock.recv(1)
    except socket.timeout:
        raise AssertionError("连接没有按协议关闭（3 秒内仍在等待数据）")
    except ConnectionResetError:
        return
    if data:
        raise AssertionError("连接关闭前收到意外数据：%r" % data)


def open_connection(peer):
    sock = socket.create_connection(("127.0.0.1", peer.port), timeout=5.0)
    sock.settimeout(5.0)
    return sock


def build_hello(**overrides):
    hello = {
        "app": rp.APP_TAG,
        "v": rp.PROTOCOL_VERSION,
        "id": CLIENT_ID,
        "name": CLIENT_NAME,
    }
    hello.update(overrides)
    return {key: value for key, value in hello.items() if value is not None}


def send_hello(conn, **overrides):
    raw_send_frame(conn, build_hello(**overrides))
    response, body_len = raw_read_frame(conn)
    return response, body_len


@contextmanager
def running_peer(**overrides):
    tmp = tempfile.mkdtemp(prefix="refpeer-proto-")
    params = dict(
        name=SERVER_NAME,
        pairing_code=PAIR_CODE,
        receive_dir=os.path.join(tmp, "recv"),
        state_path=os.path.join(tmp, "state.json"),
        enable_discovery=False,
    )
    params.update(overrides)
    peer = rp.ReferencePeer(**params)
    peer.start()
    try:
        yield peer, tmp
    finally:
        peer.stop()
        shutil.rmtree(tmp, ignore_errors=True)


def find_free_udp_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]
    finally:
        sock.close()


def find_free_tcp_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]
    finally:
        sock.close()


@contextmanager
def running_discovery(offline_after=rp.DEFAULT_OFFLINE_AFTER, prune_interval=rp.DEFAULT_PRUNE_INTERVAL):
    port = find_free_udp_port()
    seen = []
    lost = []
    service = rp.DiscoveryService(
        device_id="discovery-self-id",
        device_name="参考接收端",
        tcp_port=43210,
        discovery_port=port,
        bind_host="127.0.0.1",
        broadcast=False,
        announce_interval=60.0,
        offline_after=offline_after,
        prune_interval=prune_interval,
        on_peer=lambda peer, is_new: seen.append((peer, is_new)),
        on_peer_lost=lost.append,
    )
    service.start()
    try:
        yield service, port, seen, lost
    finally:
        service.stop()


@contextmanager
def fake_server(handler):
    """起一个只服务一次连接的假 server，用 handler(conn) 精确控制响应（验证发送方行为）。"""
    listen = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listen.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listen.bind(("127.0.0.1", 0))
    listen.listen(1)
    listen.settimeout(5.0)
    port = listen.getsockname()[1]
    thread = threading.Thread(target=_fake_server_loop, args=(listen, handler), daemon=True)
    thread.start()
    try:
        yield port
    finally:
        try:
            listen.close()
        except OSError:
            pass
        thread.join(1.0)


def _fake_server_loop(listen, handler):
    conn = None
    try:
        conn, _addr = listen.accept()
        conn.settimeout(5.0)
        handler(conn)
    except OSError:
        pass
    finally:
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass


def raw_send_announcement(port, payload):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        sock.sendto(data, ("127.0.0.1", port))
    finally:
        sock.close()


def announcement(**overrides):
    payload = {
        "app": rp.APP_TAG,
        "v": rp.PROTOCOL_VERSION,
        "id": "peer-announce-1",
        "name": "iPhone 测试",
        "port": 50000,
    }
    payload.update(overrides)
    return payload


def wait_true(predicate, timeout=3.0, interval=0.02):
    return rp.wait_until(predicate, timeout, interval) is not None


# ---------------------------------------------------------------------------
# 基类
# ---------------------------------------------------------------------------


class PeerTestCase(unittest.TestCase):
    def setUp(self):
        self._peer_ctx = running_peer()
        self.peer, self.tmp = self._peer_ctx.__enter__()
        self.addCleanup(self._peer_ctx.__exit__, None, None, None)

    def pair_connection(self, client_id=CLIENT_ID, name=CLIENT_NAME, code=PAIR_CODE):
        conn = open_connection(self.peer)
        response, _ = send_hello(conn, id=client_id, name=name, code=code)
        self.assertEqual(response.get("type"), "hello_ok", response)
        return conn

    def send_file_raw(self, conn, name, data, chunk_size=rp.FILE_CHUNK_BYTES):
        raw_send_frame(conn, {"type": "file", "name": name, "size": len(data)})
        view = memoryview(data)
        offset = 0
        while offset < len(view):
            conn.sendall(view[offset:offset + chunk_size])
            offset += chunk_size
        response, _ = raw_read_frame(conn)
        return response

    def send_file_new_connection(self, name, data, client_id=CLIENT_ID, name_of_client=CLIENT_NAME):
        conn = self.pair_connection(client_id=client_id, name=name_of_client)
        try:
            response = self.send_file_raw(conn, name, data)
            raw_send_frame(conn, {"type": "bye"})
            return response
        finally:
            conn.close()

    def recv_files(self):
        return sorted(os.listdir(os.path.join(self.tmp, "recv")))


# ---------------------------------------------------------------------------
# 常量 / 帧格式
# ---------------------------------------------------------------------------


class TestConstants(unittest.TestCase):
    def test_discovery_port_is_52730(self):
        self.assertEqual(rp.DISCOVERY_PORT, 52730)
        self.assertEqual(rp.PROTOCOL_VERSION, 1)
        self.assertEqual(rp.APP_TAG, "ADBTypeLink")

    def test_frame_and_chunk_limits(self):
        self.assertEqual(rp.MAX_FRAME_BYTES, 16 * 1024 * 1024)
        self.assertEqual(rp.FILE_CHUNK_BYTES, 256 * 1024)
        self.assertEqual(rp.CONNECT_TIMEOUT_SECONDS, 6.0)
        self.assertEqual(rp.IO_TIMEOUT_SECONDS, 30.0)

    def test_default_offline_after_is_8_seconds(self):
        self.assertEqual(rp.DEFAULT_OFFLINE_AFTER, 8.0)
        self.assertEqual(rp.DEFAULT_ANNOUNCE_INTERVAL, 2.0)

    def test_pairing_code_is_six_digits(self):
        for _ in range(300):
            code = rp.make_pairing_code()
            self.assertRegex(code, r"^[0-9]{6}$")
            self.assertEqual(len(code), 6)

    def test_pairing_code_validation(self):
        self.assertTrue(rp.is_valid_pairing_code("123456"))
        self.assertTrue(rp.is_valid_pairing_code(" 123456 "))
        self.assertTrue(rp.is_valid_pairing_code("000000"))
        self.assertFalse(rp.is_valid_pairing_code("12345"))
        self.assertFalse(rp.is_valid_pairing_code("1234567"))
        self.assertFalse(rp.is_valid_pairing_code("12345a"))
        self.assertFalse(rp.is_valid_pairing_code(None))
        self.assertFalse(rp.is_valid_pairing_code(123456))


class TestFrameHelpers(unittest.TestCase):
    def test_frame_roundtrip_with_unicode(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        message = {"type": "text", "text": "中文 / emoji 😀🎉 / 空格 "}
        rp.write_frame(left, message)
        self.assertEqual(rp.read_frame(right), message)

    def test_split_frame_is_read_completely(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        frame = rp.encode_frame({"type": "hello", "name": "拆包测试😀"})
        for index in range(len(frame)):
            left.sendall(frame[index:index + 1])
        self.assertEqual(rp.read_frame(right), {"type": "hello", "name": "拆包测试😀"})

    def test_oversized_length_is_rejected(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        left.sendall(struct.pack(">I", rp.MAX_FRAME_BYTES + 1))
        with self.assertRaises(rp.ProtocolError):
            rp.read_frame(right)

    def test_zero_length_is_rejected(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        left.sendall(struct.pack(">I", 0))
        with self.assertRaises(rp.ProtocolError):
            rp.read_frame(right)

    def test_non_object_json_is_invalid_message(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        raw_send_body(left, b"[1, 2, 3]")
        with self.assertRaises(rp.InvalidMessage):
            rp.read_frame(right)

    def test_invalid_json_is_invalid_message(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        raw_send_body(left, b"{not valid json")
        with self.assertRaises(rp.InvalidMessage):
            rp.read_frame(right)


# ---------------------------------------------------------------------------
# 握手 / 配对
# ---------------------------------------------------------------------------


class TestHandshake(PeerTestCase):
    def test_pair_required_when_no_code(self):
        conn = open_connection(self.peer)
        try:
            response, body_len = send_hello(conn)
            self.assertEqual(response.get("type"), "pair_required")
            self.assertEqual(response.get("name"), SERVER_NAME)
            self.assertEqual(body_len, len(json.dumps(response, ensure_ascii=False).encode("utf-8")))
            expect_closed(conn)
        finally:
            conn.close()
        self.assertFalse(self.peer.is_paired(CLIENT_ID))
        self.assertIn(CLIENT_ID, self.peer.pending_pair_names())

    def test_pair_ok_with_correct_code(self):
        conn = open_connection(self.peer)
        try:
            response, _ = send_hello(conn, code=PAIR_CODE)
            self.assertEqual(response.get("type"), "hello_ok")
            self.assertEqual(response.get("name"), SERVER_NAME)
            self.assertEqual(response.get("id"), self.peer.device_id)
            raw_send_frame(conn, {"type": "bye"})
            expect_closed(conn)
        finally:
            conn.close()
        self.assertTrue(self.peer.is_paired(CLIENT_ID))

    def test_pair_required_with_wrong_code(self):
        conn = open_connection(self.peer)
        try:
            response, _ = send_hello(conn, code="000000")
            self.assertEqual(response.get("type"), "pair_required")
            expect_closed(conn)
        finally:
            conn.close()
        self.assertFalse(self.peer.is_paired(CLIENT_ID))

    def test_code_whitespace_is_trimmed(self):
        conn = open_connection(self.peer)
        try:
            response, _ = send_hello(conn, code="  " + PAIR_CODE + "  ")
            self.assertEqual(response.get("type"), "hello_ok")
            raw_send_frame(conn, {"type": "bye"})
        finally:
            conn.close()

    def test_code_with_inner_space_rejected(self):
        conn = open_connection(self.peer)
        try:
            response, _ = send_hello(conn, code="246 810")
            self.assertEqual(response.get("type"), "pair_required")
        finally:
            conn.close()

    def test_already_paired_second_connection_needs_no_code(self):
        conn = self.pair_connection()
        raw_send_frame(conn, {"type": "bye"})
        expect_closed(conn)
        conn.close()
        conn2 = open_connection(self.peer)
        try:
            response, _ = send_hello(conn2)
            self.assertEqual(response.get("type"), "hello_ok")
            raw_send_frame(conn2, {"type": "bye"})
        finally:
            conn2.close()

    def test_pair_required_name_uses_server_name(self):
        conn = open_connection(self.peer)
        try:
            response, _ = send_hello(conn, name="另一台手机")
            self.assertEqual(response.get("type"), "pair_required")
            self.assertEqual(response.get("name"), SERVER_NAME)
        finally:
            conn.close()

    def test_hello_with_protocol_version_2_accepted(self):
        conn = open_connection(self.peer)
        try:
            response, _ = send_hello(conn, v=2, code=PAIR_CODE)
            self.assertEqual(response.get("type"), "hello_ok")
            raw_send_frame(conn, {"type": "bye"})
        finally:
            conn.close()

    def test_invalid_app_gets_error(self):
        self._hello_error(app="OtherApp")

    def test_missing_app_gets_error(self):
        self._hello_error(app=None)

    def test_own_device_id_gets_error(self):
        self._hello_error(id=self.peer.device_id)

    def test_missing_name_gets_error(self):
        self._hello_error(name=None)

    def test_empty_name_gets_error(self):
        self._hello_error(name="")

    def test_empty_json_object_gets_error(self):
        conn = open_connection(self.peer)
        try:
            raw_send_frame(conn, {})
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "error")
            self.assertEqual(response.get("message"), rp.HELLO_ERROR_MESSAGE)
            expect_closed(conn)
        finally:
            conn.close()

    def test_non_object_json_gets_error(self):
        conn = open_connection(self.peer)
        try:
            raw_send_body(conn, b"[1, 2, 3]")
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "error")
            self.assertEqual(response.get("message"), rp.HELLO_ERROR_MESSAGE)
            expect_closed(conn)
        finally:
            conn.close()

    def test_invalid_json_gets_error(self):
        conn = open_connection(self.peer)
        try:
            raw_send_body(conn, b"{broken json")
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "error")
            self.assertEqual(response.get("message"), rp.HELLO_ERROR_MESSAGE)
            expect_closed(conn)
        finally:
            conn.close()

    def test_invalid_utf8_gets_error(self):
        conn = open_connection(self.peer)
        try:
            raw_send_body(conn, bytes([0xff, 0xfe, 0x00]))
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "error")
            self.assertEqual(response.get("message"), rp.HELLO_ERROR_MESSAGE)
            expect_closed(conn)
        finally:
            conn.close()

    def test_oversized_frame_header_closes(self):
        conn = open_connection(self.peer)
        try:
            conn.sendall(struct.pack(">I", rp.MAX_FRAME_BYTES + 1))
            expect_closed(conn)
        finally:
            conn.close()

    def test_zero_length_frame_closes(self):
        conn = open_connection(self.peer)
        try:
            conn.sendall(struct.pack(">I", 0))
            expect_closed(conn)
        finally:
            conn.close()

    def test_little_endian_length_closes(self):
        conn = open_connection(self.peer)
        try:
            body = json.dumps(build_hello(), ensure_ascii=False).encode("utf-8")
            conn.sendall(struct.pack("<I", len(body)) + body)
            expect_closed(conn)
        finally:
            conn.close()

    def test_server_survives_bad_connections(self):
        for _ in range(5):
            conn = open_connection(self.peer)
            try:
                conn.sendall(b"GET / HTTP/1.1")
                expect_closed(conn)
            finally:
                conn.close()
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "text", "text": "坏连接之后仍然正常"})
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "ok")
        finally:
            conn.close()

    def test_split_hello_bytes_still_handshakes(self):
        conn = open_connection(self.peer)
        try:
            body = json.dumps(build_hello(), ensure_ascii=False).encode("utf-8")
            frame = struct.pack(">I", len(body)) + body
            for index in range(len(frame)):
                conn.sendall(frame[index:index + 1])
                time.sleep(0.002)
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "pair_required")
        finally:
            conn.close()

    def test_client_pair_only_wrong_then_right_code(self):
        wrong = rp.pair_only(
            "127.0.0.1", self.peer.port, "000000", CLIENT_ID, CLIENT_NAME
        )
        self.assertEqual(wrong.kind, "need_pair")
        self.assertEqual(wrong.message, rp.WRONG_CODE_MESSAGE)
        self.assertFalse(self.peer.is_paired(CLIENT_ID))
        good = rp.pair_only("127.0.0.1", self.peer.port, PAIR_CODE, CLIENT_ID, CLIENT_NAME)
        self.assertTrue(good.ok, good)
        self.assertEqual(good.message, "已与「%s」配对，可以直接发送文字和文件" % SERVER_NAME)
        self.assertTrue(self.peer.is_paired(CLIENT_ID))

    def _hello_error(self, **overrides):
        conn = open_connection(self.peer)
        try:
            response, _ = send_hello(conn, **overrides)
            self.assertEqual(response.get("type"), "error")
            self.assertEqual(response.get("message"), rp.HELLO_ERROR_MESSAGE)
            expect_closed(conn)
        finally:
            conn.close()


class TestClientProtocol(unittest.TestCase):
    """用假 server 精确验证发送方（spec 4.4 / 5 / 6）的行为。"""

    def test_client_handles_error_response(self):
        def handler(conn):
            rp.read_frame(conn)
            rp.write_frame(conn, {"type": "error", "message": "协议不匹配，请升级两端应用"})

        with fake_server(handler) as port:
            result = rp.send_text("127.0.0.1", port, "不会发出", "client-fake", "Python 手机端")
        self.assertEqual(result.kind, "error")
        self.assertEqual(result.message, "协议不匹配，请升级两端应用")

    def test_client_handles_unknown_handshake_response(self):
        def handler(conn):
            rp.read_frame(conn)
            rp.write_frame(conn, {"type": "weird"})

        with fake_server(handler) as port:
            result = rp.send_text("127.0.0.1", port, "不会发出", "client-fake", "Python 手机端")
        self.assertEqual(result.kind, "protocol_mismatch")
        self.assertEqual(result.message, rp.PROTOCOL_MISMATCH_MESSAGE)

    def test_client_handles_no_response(self):
        def handler(conn):
            conn.close()

        with fake_server(handler) as port:
            result = rp.send_text("127.0.0.1", port, "不会发出", "client-fake", "Python 手机端")
        self.assertEqual(result.kind, "no_response")
        self.assertEqual(result.message, rp.NO_RESPONSE_MESSAGE)

    def test_client_reports_missing_text_ack(self):
        def handler(conn):
            rp.read_frame(conn)
            rp.write_frame(conn, {"type": "hello_ok", "name": "假电脑", "id": "fake-peer"})
            rp.read_frame(conn)
            # 不回 ok，直接关闭

        with fake_server(handler) as port:
            result = rp.send_text("127.0.0.1", port, "没有确认", "client-fake", "Python 手机端")
        self.assertEqual(result.kind, "no_ack")
        self.assertEqual(result.message, rp.TEXT_NOT_ACKED_MESSAGE)

    def test_client_sends_bye_after_text_ack(self):
        received = []

        def handler(conn):
            received.append(rp.read_frame(conn))
            rp.write_frame(conn, {"type": "hello_ok", "name": "假电脑", "id": "fake-peer"})
            received.append(rp.read_frame(conn))
            rp.write_frame(conn, {"type": "ok"})
            received.append(rp.read_frame(conn))

        with fake_server(handler) as port:
            result = rp.send_text("127.0.0.1", port, "带 bye", "client-fake", "Python 手机端")
        self.assertTrue(result.ok, result)
        self.assertNotIn("type", received[0])
        self.assertEqual(received[0]["app"], rp.APP_TAG)
        self.assertEqual(received[0]["v"], 1)
        self.assertEqual(received[0]["id"], "client-fake")
        self.assertEqual(received[0]["name"], "Python 手机端")
        self.assertEqual(received[1]["type"], "text")
        self.assertEqual(received[1]["text"], "带 bye")
        self.assertEqual(received[2]["type"], "bye")

    def test_client_streams_exact_file_bytes_and_sends_bye(self):
        import hashlib as local_hashlib

        data = os.urandom(600000)
        seen = {}

        def handler(conn):
            hello = rp.read_frame(conn)
            seen["hello"] = hello
            rp.write_frame(conn, {"type": "hello_ok", "name": "假电脑", "id": "fake-peer"})
            header = rp.read_frame(conn)
            seen["header"] = header
            body = rp.read_exact(conn, header["size"])
            seen["body"] = body
            rp.write_frame(conn, {"type": "ok"})
            seen["bye"] = rp.read_frame(conn)

        tmp = tempfile.mkdtemp(prefix="refpeer-fakefile-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "分块发送.bin")
        with open(path, "wb") as handle:
            handle.write(data)
        with fake_server(handler) as port:
            result = rp.send_file("127.0.0.1", port, path, "client-fake", "Python 手机端")
        self.assertTrue(result.ok, result)
        self.assertEqual(seen["header"]["type"], "file")
        self.assertEqual(seen["header"]["name"], "分块发送.bin")
        self.assertEqual(seen["header"]["size"], len(data))
        self.assertEqual(seen["body"], data)
        self.assertEqual(seen["bye"]["type"], "bye")


class TestPairingPersistence(unittest.TestCase):
    def test_pairing_persists_across_restart(self):
        tmp = tempfile.mkdtemp(prefix="refpeer-persist-")
        self.addCleanup(shutil.rmtree, tmp, True)
        state_path = os.path.join(tmp, "state.json")
        receive_dir = os.path.join(tmp, "recv")
        peer1 = rp.ReferencePeer(
            name=SERVER_NAME,
            pairing_code=PAIR_CODE,
            receive_dir=receive_dir,
            state_path=state_path,
            enable_discovery=False,
        )
        peer1.start()
        device_id = peer1.device_id
        conn = open_connection(peer1)
        try:
            response, _ = send_hello(conn, code=PAIR_CODE)
            self.assertEqual(response.get("type"), "hello_ok")
            raw_send_frame(conn, {"type": "bye"})
        finally:
            conn.close()
        peer1.stop()

        peer2 = rp.ReferencePeer(
            name=SERVER_NAME,
            pairing_code=PAIR_CODE,
            receive_dir=receive_dir,
            state_path=state_path,
            enable_discovery=False,
        )
        peer2.start()
        try:
            self.assertEqual(peer2.device_id, device_id)
            self.assertTrue(peer2.is_paired(CLIENT_ID))
            conn = open_connection(peer2)
            try:
                response, _ = send_hello(conn)
                self.assertEqual(response.get("type"), "hello_ok")
                raw_send_frame(conn, {"type": "bye"})
            finally:
                conn.close()
        finally:
            peer2.stop()


# ---------------------------------------------------------------------------
# 文字
# ---------------------------------------------------------------------------


class TestText(PeerTestCase):
    def test_chinese_emoji_text_roundtrip(self):
        text = "你好，世界 👋 中文测试 🚀🎉 換行前後 "
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "text", "text": text})
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "ok")
            messages = self.peer.received_texts()
            self.assertEqual(len(messages), 1)
            self.assertEqual(messages[0]["text"], text)
            self.assertEqual(messages[0]["peerName"], CLIENT_NAME)
            raw_send_frame(conn, {"type": "bye"})
            expect_closed(conn)
        finally:
            conn.close()

    def test_multiline_text_roundtrip(self):
        text = "第一行" + chr(10) + "第二行" + chr(10) + chr(10) + "结尾😀"
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "text", "text": text})
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "ok")
            self.assertEqual(self.peer.received_texts()[0]["text"], text)
        finally:
            conn.close()

    def test_large_text_frame(self):
        text = "长" * 200000 + "😀"
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "text", "text": text})
            response, body_len = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "ok")
            self.assertGreater(body_len, 0)
            self.assertEqual(self.peer.received_texts()[0]["text"], text)
        finally:
            conn.close()

    def test_multiple_text_messages_one_connection(self):
        conn = self.pair_connection()
        try:
            for index in range(3):
                raw_send_frame(conn, {"type": "text", "text": "第 %d 条" % index})
                response, _ = raw_read_frame(conn)
                self.assertEqual(response.get("type"), "ok")
            self.assertEqual(len(self.peer.received_texts()), 3)
        finally:
            conn.close()

    def test_text_then_file_same_connection(self):
        conn = self.pair_connection()
        data = b"file-after-text" * 100
        try:
            raw_send_frame(conn, {"type": "text", "text": "先文字"})
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "ok")
            response = self.send_file_raw(conn, "同连接文件.txt", data)
            self.assertEqual(response.get("type"), "ok")
            self.assertEqual(len(self.peer.received_texts()), 1)
            self.assertEqual(len(self.peer.received_files()), 1)
            files = self.peer.received_files()
            with open(files[0]["savedPath"], "rb") as handle:
                self.assertEqual(handle.read(), data)
        finally:
            conn.close()

    def test_unknown_type_closes_connection(self):
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "bogus", "hello": 1})
            expect_closed(conn)
        finally:
            conn.close()
        self.assertEqual(self.peer.received_texts(), [])

    def test_text_without_text_field_closes(self):
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "text"})
            expect_closed(conn)
        finally:
            conn.close()

    def test_text_with_non_string_text_closes(self):
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "text", "text": 123})
            expect_closed(conn)
        finally:
            conn.close()

    def test_client_rejects_empty_text_locally(self):
        for value in ("", "   ", chr(10) + "  "):
            result = rp.send_text("127.0.0.1", self.peer.port, value, CLIENT_ID, CLIENT_NAME)
            self.assertEqual(result.kind, "empty_text")
            self.assertEqual(result.message, rp.EMPTY_TEXT_MESSAGE)
            self.assertFalse(result.connection_made)
        self.assertEqual(self.peer.connection_count, 0)

    def test_client_text_flow_with_and_without_code(self):
        result = rp.send_text(
            "127.0.0.1", self.peer.port, "客户端库发来的中文 😀", CLIENT_ID, CLIENT_NAME, code=PAIR_CODE
        )
        self.assertTrue(result.ok, result)
        self.assertEqual(self.peer.received_texts()[0]["text"], "客户端库发来的中文 😀")

        result = rp.send_text("127.0.0.1", self.peer.port, "第二次无需配对码", CLIENT_ID, CLIENT_NAME)
        self.assertTrue(result.ok, result)
        self.assertEqual(len(self.peer.received_texts()), 2)

    def test_client_pair_required_message(self):
        result = rp.send_text("127.0.0.1", self.peer.port, "未配对", CLIENT_ID, CLIENT_NAME)
        self.assertEqual(result.kind, "need_pair")
        self.assertIn(SERVER_NAME, result.message)
        self.assertIn("6 位配对码", result.message)

    def test_client_connect_failure_message(self):
        port = find_free_tcp_port()
        result = rp.send_text("127.0.0.1", port, "发不出去", CLIENT_ID, CLIENT_NAME)
        self.assertEqual(result.kind, "connect_failed")
        self.assertIn("连不上", result.message)
        self.assertFalse(result.connection_made)


# ---------------------------------------------------------------------------
# 文件
# ---------------------------------------------------------------------------


class TestFiles(PeerTestCase):
    def test_file_roundtrip_sha256(self):
        data = os.urandom(700000)
        conn = self.pair_connection()
        try:
            response = self.send_file_raw(conn, "测试文件.bin", data)
            self.assertEqual(response.get("type"), "ok")
            raw_send_frame(conn, {"type": "bye"})
            expect_closed(conn)
        finally:
            conn.close()
        files = self.peer.received_files()
        self.assertEqual(len(files), 1)
        message = files[0]
        self.assertEqual(message["originalName"], "测试文件.bin")
        self.assertEqual(message["savedName"], "测试文件.bin")
        self.assertEqual(message["size"], len(data))
        self.assertEqual(message["sha256"], hashlib.sha256(data).hexdigest())
        with open(message["savedPath"], "rb") as handle:
            self.assertEqual(handle.read(), data)
        self.assertIn("测试文件.bin", self.recv_files())

    def test_zero_byte_file_accepted(self):
        conn = self.pair_connection()
        try:
            response = self.send_file_raw(conn, "空文件.txt", b"")
            self.assertEqual(response.get("type"), "ok")
        finally:
            conn.close()
        files = self.peer.received_files()
        self.assertEqual(files[0]["size"], 0)
        self.assertEqual(os.path.getsize(files[0]["savedPath"]), 0)

    def test_duplicate_names_numbered(self):
        payloads = [b"one", b"two-two", b"three-three-three"]
        for payload in payloads:
            response = self.send_file_new_connection("重复.txt", payload)
            self.assertEqual(response.get("type"), "ok")
        self.assertEqual(self.recv_files(), ["重复 (2).txt", "重复 (3).txt", "重复.txt"])
        contents = []
        for name in ("重复.txt", "重复 (2).txt", "重复 (3).txt"):
            with open(os.path.join(self.tmp, "recv", name), "rb") as handle:
                contents.append(handle.read())
        self.assertEqual(contents, payloads)

    def test_dotfile_duplicate_numbering(self):
        self.send_file_new_connection(".env", b"A=1")
        self.send_file_new_connection(".env", b"A=2")
        self.assertEqual(self.recv_files(), [".env", ".env (2)"])
        with open(os.path.join(self.tmp, "recv", ".env (2)"), "rb") as handle:
            self.assertEqual(handle.read(), b"A=2")

    def test_multi_extension_duplicate_numbering(self):
        self.send_file_new_connection("a.tar.gz", b"first")
        self.send_file_new_connection("a.tar.gz", b"second")
        self.assertEqual(self.recv_files(), ["a.tar (2).gz", "a.tar.gz"])

    def test_path_is_reduced_to_last_component(self):
        response = self.send_file_new_connection("/tmp/绝对路径.txt", b"abs")
        self.assertEqual(response.get("type"), "ok")
        windows_path = "C:" + chr(92) + "Users" + chr(92) + "用户" + chr(92) + "文件.txt"
        response = self.send_file_new_connection(windows_path, b"win")
        self.assertEqual(response.get("type"), "ok")
        self.assertEqual(self.recv_files(), ["文件.txt", "绝对路径.txt"])

    def test_invalid_names_get_error(self):
        for name in ("..", ".", "", "dir/"):
            conn = self.pair_connection()
            try:
                raw_send_frame(conn, {"type": "file", "name": name, "size": 1})
                response, _ = raw_read_frame(conn)
                self.assertEqual(response.get("type"), "error", "name=%r" % name)
                self.assertEqual(response.get("message"), rp.SAVE_FAILED_MESSAGE)
                expect_closed(conn)
            finally:
                conn.close()
        self.assertEqual(self.recv_files(), [])
        self.assertEqual(self.peer.messages, [])

    def test_truncated_file_cleans_partial(self):
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "file", "name": "半截.bin", "size": 1000})
            conn.sendall(b"x" * 100)
        finally:
            conn.close()
        # 等接收线程真正处理完（建文件 -> 读失败 -> 删半截文件）再断言，避免竞态。
        self.assertTrue(
            wait_true(lambda: self.peer.active_connections == 0, timeout=5.0),
            "接收线程没有在 5 秒内结束",
        )
        self.assertEqual(self.recv_files(), [])
        self.assertEqual(self.peer.received_files(), [])

    def test_file_written_in_small_chunks(self):
        data = os.urandom(100000)
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "file", "name": "小分块.bin", "size": len(data)})
            for offset in range(0, len(data), 1000):
                conn.sendall(data[offset:offset + 1000])
                time.sleep(0.001)
            response, _ = raw_read_frame(conn)
            self.assertEqual(response.get("type"), "ok")
        finally:
            conn.close()
        files = self.peer.received_files()
        with open(files[0]["savedPath"], "rb") as handle:
            self.assertEqual(handle.read(), data)

    def test_client_rejects_zero_byte_file(self):
        path = os.path.join(self.tmp, "empty.bin")
        with open(path, "wb"):
            pass
        result = rp.send_file("127.0.0.1", self.peer.port, path, CLIENT_ID, CLIENT_NAME, code=PAIR_CODE)
        self.assertEqual(result.kind, "bad_file")
        self.assertIn("读不到文件", result.message)
        self.assertFalse(result.connection_made)
        self.assertEqual(self.peer.connection_count, 0)

    def test_client_rejects_missing_file(self):
        result = rp.send_file(
            "127.0.0.1", self.peer.port, os.path.join(self.tmp, "不存在.bin"), CLIENT_ID, CLIENT_NAME, code=PAIR_CODE
        )
        self.assertEqual(result.kind, "bad_file")
        self.assertIn("读不到文件", result.message)

    def test_client_file_flow_with_name_override(self):
        path = os.path.join(self.tmp, "本地名字.bin")
        data = os.urandom(300000)
        with open(path, "wb") as handle:
            handle.write(data)
        result = rp.send_file(
            "127.0.0.1",
            self.peer.port,
            path,
            CLIENT_ID,
            CLIENT_NAME,
            code=PAIR_CODE,
            file_name="报告 2026 (最终).bin",
        )
        self.assertTrue(result.ok, result)
        files = self.peer.received_files()
        self.assertEqual(files[0]["originalName"], "报告 2026 (最终).bin")
        self.assertEqual(files[0]["savedName"], "报告 2026 (最终).bin")
        self.assertEqual(files[0]["sha256"], hashlib.sha256(data).hexdigest())

    def test_file_header_invalid_size_closes(self):
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "file", "name": "x.bin", "size": -1})
            expect_closed(conn)
        finally:
            conn.close()

    def test_file_header_missing_name_closes(self):
        conn = self.pair_connection()
        try:
            raw_send_frame(conn, {"type": "file", "size": 10})
            expect_closed(conn)
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# 设备发现
# ---------------------------------------------------------------------------


class TestDiscovery(unittest.TestCase):
    def test_valid_announcement_discovered(self):
        with running_discovery() as (service, port, seen, lost):
            raw_send_announcement(port, announcement())
            self.assertTrue(wait_true(lambda: service.peers(), timeout=2.0))
            peers = service.peers()
            self.assertEqual(len(peers), 1)
            peer = peers[0]
            self.assertEqual(peer.id, "peer-announce-1")
            self.assertEqual(peer.name, "iPhone 测试")
            self.assertEqual(peer.host, "127.0.0.1")
            self.assertEqual(peer.port, 50000)
            self.assertEqual(len(seen), 1)
            self.assertTrue(seen[0][1])

    def test_source_ip_is_used_not_payload_host(self):
        with running_discovery() as (service, port, seen, lost):
            raw_send_announcement(port, announcement(host="1.2.3.4"))
            self.assertTrue(wait_true(lambda: service.peers(), timeout=2.0))
            self.assertEqual(service.peers()[0].host, "127.0.0.1")

    def test_invalid_announcements_ignored(self):
        invalid_payloads = [
            announcement(app="OtherApp"),
            announcement(app=None),
            announcement(id=""),
            announcement(id="   "),
            announcement(id=None),
            announcement(id="discovery-self-id"),
            announcement(name=""),
            announcement(name="   "),
            announcement(name=None),
            announcement(port=0),
            announcement(port=65536),
            announcement(port=-1),
            announcement(port="50000"),
            announcement(port=None),
            announcement(port=True),
            b"not json at all",
            b"[1, 2, 3]",
            b"null",
        ]
        with running_discovery() as (service, port, seen, lost):
            for payload in invalid_payloads:
                raw_send_announcement(port, payload)
            time.sleep(0.4)
            self.assertEqual(service.peers(), [])
            self.assertEqual(seen, [])

    def test_own_id_ignored(self):
        with running_discovery() as (service, port, seen, lost):
            raw_send_announcement(port, announcement(id="discovery-self-id"))
            time.sleep(0.3)
            self.assertEqual(service.peers(), [])

    def test_peer_refreshed_not_duplicated(self):
        with running_discovery() as (service, port, seen, lost):
            raw_send_announcement(port, announcement())
            self.assertTrue(wait_true(lambda: service.peers(), timeout=2.0))
            raw_send_announcement(port, announcement(name="改过的名字"))
            self.assertTrue(wait_true(lambda: service.peers()[0].name == "改过的名字", timeout=2.0))
            self.assertEqual(len(service.peers()), 1)
            self.assertEqual([item[1] for item in seen], [True, False])

    def test_protocol_version_2_accepted(self):
        with running_discovery() as (service, port, seen, lost):
            raw_send_announcement(port, announcement(v=2))
            self.assertTrue(wait_true(lambda: service.peers(), timeout=2.0))
            self.assertEqual(service.peers()[0].version, 2)

    def test_peer_pruned_after_offline_timeout(self):
        with running_discovery(offline_after=0.4, prune_interval=0.05) as (service, port, seen, lost):
            raw_send_announcement(port, announcement())
            self.assertTrue(wait_true(lambda: service.peers(), timeout=2.0))
            self.assertTrue(wait_true(lambda: not service.peers(), timeout=2.5))
            self.assertEqual([peer.id for peer in lost], ["peer-announce-1"])

    def test_announcement_payload_matches_spec(self):
        service = rp.DiscoveryService(
            device_id="payload-device-id",
            device_name="中文电脑名",
            tcp_port=54321,
            discovery_port=12345,
            broadcast=False,
        )
        payload = service.announcement_payload()
        self.assertIsNotNone(payload)
        obj = json.loads(payload.decode("utf-8"))
        self.assertEqual(obj["app"], "ADBTypeLink")
        self.assertEqual(obj["v"], 1)
        self.assertEqual(obj["id"], "payload-device-id")
        self.assertEqual(obj["name"], "中文电脑名")
        self.assertEqual(obj["port"], 54321)


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------


class TestHelpers(unittest.TestCase):
    def test_sanitize_file_name(self):
        self.assertEqual(rp.sanitize_file_name("a/b/c.txt"), "c.txt")
        self.assertEqual(rp.sanitize_file_name("/tmp/x.txt"), "x.txt")
        self.assertEqual(rp.sanitize_file_name("C:" + chr(92) + "Users" + chr(92) + "x.txt"), "x.txt")
        self.assertEqual(rp.sanitize_file_name("普通名字.txt"), "普通名字.txt")
        self.assertIsNone(rp.sanitize_file_name(""))
        self.assertIsNone(rp.sanitize_file_name("."))
        self.assertIsNone(rp.sanitize_file_name(".."))
        self.assertIsNone(rp.sanitize_file_name("a/"))
        self.assertIsNone(rp.sanitize_file_name("a/.."))

    def test_allocate_receive_path_numbering(self):
        tmp = tempfile.mkdtemp(prefix="refpeer-name-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path, name = rp.allocate_receive_path(tmp, "报告.txt")
        self.assertEqual(name, "报告.txt")
        open(path, "wb").close()
        path2, name2 = rp.allocate_receive_path(tmp, "报告.txt")
        self.assertEqual(name2, "报告 (2).txt")
        open(path2, "wb").close()
        path3, name3 = rp.allocate_receive_path(tmp, "报告.txt")
        self.assertEqual(name3, "报告 (3).txt")

    def test_wait_until_returns_value_or_none(self):
        self.assertEqual(rp.wait_until(lambda: 42, 0.1), 42)
        start = time.monotonic()
        self.assertIsNone(rp.wait_until(lambda: None, 0.2))
        self.assertLess(time.monotonic() - start, 2.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
