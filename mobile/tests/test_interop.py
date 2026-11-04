#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""端到端联调自测：两个参考对端互发 + 真实 CLI 子进程。

覆盖：
- 两台参考对端在真实 UDP 52730 上互相发现（广播）；
- 配对码错误 / 正确、已配对免码；
- 中文 / emoji 文字双向、逐字节一致的文件双向；
- 多文件各自新建 TCP 连接；
- reference_peer.py 的 serve / discover / pair / send-text / send-file 子命令；
- run_reference_peer.py 的脚本模式（接收手机文字/文件、主动配对并发送）。

运行：

    cd mobile/tests
    python3 -m unittest -v test_interop.py
    # 或
    ./run_tests.sh
"""

import hashlib
import json
import os
import queue
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager

import reference_peer as rp

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE_PEER = os.path.join(HERE, "reference_peer.py")
RUN_PEER = os.path.join(HERE, "run_reference_peer.py")
PYTHON = sys.executable or "python3"

PAIR_CODE = "135790"
PHONE_NAME = "联调手机端"


# ---------------------------------------------------------------------------
# 子进程输出读取
# ---------------------------------------------------------------------------


class ProcessOutput:
    """后台线程收集子进程 stdout（stderr 已合并），支持按行等待。"""

    def __init__(self, process):
        self.process = process
        self.lines = []
        self._queue = queue.Queue()
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()

    def _pump(self):
        try:
            for raw in self.process.stdout:
                line = raw.rstrip(chr(10))
                self.lines.append(line)
                self._queue.put(line)
        finally:
            self._queue.put(None)

    def wait_for(self, predicate, timeout=15.0, description="输出"):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(
                    "等待%s超时（%.1fs）；进程最近输出：%s"
                    % (description, timeout, chr(10).join(self.lines[-40:]))
                )
            try:
                line = self._queue.get(timeout=remaining)
            except queue.Empty:
                raise AssertionError(
                    "等待%s超时（%.1fs）；进程最近输出：%s"
                    % (description, timeout, chr(10).join(self.lines[-40:]))
                )
            if line is None:
                raise AssertionError(
                    "进程提前退出；最近输出：%s" % chr(10).join(self.lines[-40:])
                )
            if predicate(line):
                return line

    def wait_ready(self, timeout=20.0):
        return self.wait_for(lambda line: line.startswith("READY "), timeout, "READY")

    def events(self, event_name):
        results = []
        for line in self.lines:
            event = parse_event_line(line)
            if event is not None and event.get("event") == event_name:
                results.append(event)
        return results


def parse_event_line(line):
    if not line.startswith("EVENT "):
        return None
    try:
        return json.loads(line[len("EVENT "):])
    except ValueError:
        return None


def wait_event(output, event_name, timeout=10.0):
    # 先查已经收到的行，避免测试先等后一个事件时把前一个事件“消费”掉。
    for line in list(output.lines):
        event = parse_event_line(line)
        if event is not None and event.get("event") == event_name:
            return event
    line = output.wait_for(
        lambda item: (parse_event_line(item) or {}).get("event") == event_name,
        timeout,
        "事件 " + event_name,
    )
    return parse_event_line(line)


def parse_ready(line):
    code_match = re.search(r" code=([0-9]{6}) ", line)
    tcp_match = re.search(r" tcp=([0-9]+) ", line)
    device_match = re.search(r"device=([^ ]+) ", line)
    if not code_match or not tcp_match:
        raise AssertionError("READY 行格式意外：%r" % line)
    return {
        "code": code_match.group(1),
        "port": int(tcp_match.group(1)),
        "device_id": device_match.group(1) if device_match else "",
        "line": line,
    }


def run_cli(script_path, args, timeout=30):
    command = [PYTHON, "-u", script_path] + args
    result = subprocess.run(
        command,
        cwd=HERE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        timeout=timeout,
    )
    return result.returncode, result.stdout


@contextmanager
def running_cli(script_path, args, description="CLI", timeout=20.0, wait_ready=True):
    process = subprocess.Popen(
        [PYTHON, "-u", script_path] + args,
        cwd=HERE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        bufsize=1,
    )
    output = ProcessOutput(process)
    info = None
    try:
        if wait_ready:
            line = output.wait_ready(timeout)
            info = parse_ready(line)
        yield process, output, info
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        try:
            process.stdout.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# 参考对端 / 临时文件
# ---------------------------------------------------------------------------


@contextmanager
def running_peer(**overrides):
    tmp = tempfile.mkdtemp(prefix="refpeer-interop-")
    params = dict(
        name=PHONE_NAME,
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


def make_file(directory, name, data):
    path = os.path.join(directory, name)
    with open(path, "wb") as handle:
        handle.write(data)
    return path


def read_file(path):
    with open(path, "rb") as handle:
        return handle.read()


# ---------------------------------------------------------------------------
# 两台参考对端：发现 + 收发
# ---------------------------------------------------------------------------


class TestPeerDiscovery(unittest.TestCase):
    def test_two_peers_discover_each_other_on_default_port(self):
        first_name = "联调端-A-" + str(os.getpid())
        second_name = "联调端-B-" + str(os.getpid())
        with running_peer(
            name=first_name,
            enable_discovery=True,
            discovery_port=rp.DISCOVERY_PORT,
            announce_interval=0.5,
        ) as (first, first_tmp):
            with running_peer(
                name=second_name,
                enable_discovery=True,
                discovery_port=rp.DISCOVERY_PORT,
                announce_interval=0.5,
            ) as (second, second_tmp):
                first_sees_second = first.wait_for_peer(second_name, 12.0)
                second_sees_first = second.wait_for_peer(first_name, 12.0)
                self.assertIsNotNone(
                    first_sees_second,
                    "A 没有发现 B；附近设备=%r（若本机禁止 UDP 广播请检查本地网络权限）"
                    % ([peer.name for peer in first.discovery.peers()],),
                )
                self.assertIsNotNone(
                    second_sees_first,
                    "B 没有发现 A；附近设备=%r" % ([peer.name for peer in second.discovery.peers()],),
                )
                self.assertEqual(first_sees_second.port, second.port)
                self.assertEqual(second_sees_first.port, first.port)
                self.assertEqual(first_sees_second.host, second_sees_first.host)
                self.assertNotEqual(first.device_id, second.device_id)


class TestPeerToPeer(unittest.TestCase):
    def setUp(self):
        self._receiver_ctx = running_peer(name="接收端-" + str(os.getpid()), pairing_code=PAIR_CODE)
        self.receiver, self.receiver_tmp = self._receiver_ctx.__enter__()
        self.addCleanup(self._receiver_ctx.__exit__, None, None, None)
        self._sender_ctx = running_peer(name="发送端-" + str(os.getpid()), pairing_code="246810")
        self.sender, self.sender_tmp = self._sender_ctx.__enter__()
        self.addCleanup(self._sender_ctx.__exit__, None, None, None)

    def receiver_texts(self):
        return [message["text"] for message in self.receiver.received_texts()]

    def test_pair_required_then_pair_with_correct_code(self):
        result = rp.send_text(
            "127.0.0.1",
            self.receiver.port,
            "配对前的文字",
            self.sender.device_id,
            self.sender.device_name,
        )
        self.assertEqual(result.kind, "need_pair")
        self.assertIn(self.receiver.device_name, result.message)
        self.assertIn(self.sender.device_id, self.receiver.pending_pair_names())

        result = rp.send_text(
            "127.0.0.1",
            self.receiver.port,
            "配对后的文字",
            self.sender.device_id,
            self.sender.device_name,
            code=PAIR_CODE,
        )
        self.assertTrue(result.ok, result)
        self.assertTrue(self.receiver.is_paired(self.sender.device_id))
        self.assertEqual(self.receiver_texts(), ["配对后的文字"])

        result = rp.send_text(
            "127.0.0.1",
            self.receiver.port,
            "第二次无需配对码",
            self.sender.device_id,
            self.sender.device_name,
        )
        self.assertTrue(result.ok, result)
        self.assertEqual(self.receiver_texts(), ["配对后的文字", "第二次无需配对码"])

    def test_chinese_and_emoji_text_both_directions(self):
        from_sender = "发送端 → 接收端：你好，世界 👋 中文 😀🦄"
        from_receiver = "接收端 → 发送端：反向中文 🚀🎉 繁體字"
        result = rp.send_text(
            "127.0.0.1",
            self.receiver.port,
            from_sender,
            self.sender.device_id,
            self.sender.device_name,
            code=PAIR_CODE,
        )
        self.assertTrue(result.ok, result)
        result = rp.send_text(
            "127.0.0.1",
            self.sender.port,
            from_receiver,
            self.receiver.device_id,
            self.receiver.device_name,
            code="246810",
        )
        self.assertTrue(result.ok, result)
        self.assertEqual(self.receiver_texts(), [from_sender])
        self.assertEqual([message["text"] for message in self.sender.received_texts()], [from_receiver])

    def test_file_roundtrip_sha256(self):
        data = os.urandom(700000)
        path = make_file(self.sender_tmp, "发送端文件.bin", data)
        result = rp.send_file(
            "127.0.0.1",
            self.receiver.port,
            path,
            self.sender.device_id,
            self.sender.device_name,
            code=PAIR_CODE,
        )
        self.assertTrue(result.ok, result)
        files = self.receiver.received_files()
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0]["originalName"], "发送端文件.bin")
        self.assertEqual(files[0]["size"], len(data))
        self.assertEqual(files[0]["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(read_file(files[0]["savedPath"]), data)

        reverse_data = os.urandom(257 * 1024)
        reverse_path = make_file(self.receiver_tmp, "反向文件.bin", reverse_data)
        result = rp.send_file(
            "127.0.0.1",
            self.sender.port,
            reverse_path,
            self.receiver.device_id,
            self.receiver.device_name,
            code="246810",
        )
        self.assertTrue(result.ok, result)
        reverse_files = self.sender.received_files()
        self.assertEqual(reverse_files[0]["sha256"], hashlib.sha256(reverse_data).hexdigest())
        self.assertEqual(read_file(reverse_files[0]["savedPath"]), reverse_data)

    def test_multiple_files_use_separate_connections(self):
        first = make_file(self.sender_tmp, "一.bin", os.urandom(1000))
        second = make_file(self.sender_tmp, "二.bin", os.urandom(2000))
        for path in (first, second):
            result = rp.send_file(
                "127.0.0.1",
                self.receiver.port,
                path,
                self.sender.device_id,
                self.sender.device_name,
                code=PAIR_CODE,
            )
            self.assertTrue(result.ok, result)
        self.assertEqual(self.receiver.connection_count, 2)
        self.assertEqual(len(self.receiver.received_files()), 2)

    def test_empty_text_and_zero_byte_file_do_not_connect(self):
        empty_text = rp.send_text(
            "127.0.0.1",
            self.receiver.port,
            "   ",
            self.sender.device_id,
            self.sender.device_name,
        )
        self.assertEqual(empty_text.kind, "empty_text")
        empty_path = make_file(self.sender_tmp, "空.bin", b"")
        empty_file = rp.send_file(
            "127.0.0.1",
            self.receiver.port,
            empty_path,
            self.sender.device_id,
            self.sender.device_name,
        )
        self.assertEqual(empty_file.kind, "bad_file")
        self.assertEqual(self.receiver.connection_count, 0)


# ---------------------------------------------------------------------------
# reference_peer.py CLI
# ---------------------------------------------------------------------------


class TestCliServe(unittest.TestCase):
    def test_cli_serve_receives_text_and_file(self):
        tmp = tempfile.mkdtemp(prefix="refpeer-cli-")
        self.addCleanup(shutil.rmtree, tmp, True)
        receive_dir = os.path.join(tmp, "recv")
        args = [
            REFERENCE_PEER,
            "serve",
            "--name",
            "CLI 接收端 " + str(os.getpid()),
            "--code",
            PAIR_CODE,
            "--receive-dir",
            receive_dir,
            "--state",
            os.path.join(tmp, "state.json"),
            "--no-broadcast",
            "--seconds",
            "60",
        ]
        with running_cli(REFERENCE_PEER, args[1:], "serve") as (process, output, info):
            self.assertEqual(info["code"], PAIR_CODE)

            result = rp.send_text(
                "127.0.0.1", info["port"], "配对前的文字", "cli-client-1", "CLI 测试手机"
            )
            self.assertEqual(result.kind, "need_pair")
            event = wait_event(output, "pair_request")
            self.assertEqual(event["name"], "CLI 测试手机")

            text = "CLI 接收：中文 😀 与 emoji 🎉"
            result = rp.send_text(
                "127.0.0.1", info["port"], text, "cli-client-1", "CLI 测试手机", code=PAIR_CODE
            )
            self.assertTrue(result.ok, result)
            event = wait_event(output, "text")
            self.assertEqual(event["text"], text)

            data = os.urandom(700000)
            path = make_file(tmp, "CLI 文件.bin", data)
            result = rp.send_file(
                "127.0.0.1", info["port"], path, "cli-client-1", "CLI 测试手机"
            )
            self.assertTrue(result.ok, result)
            event = wait_event(output, "file")
            self.assertEqual(event["originalName"], "CLI 文件.bin")
            self.assertEqual(event["size"], len(data))
            self.assertEqual(event["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(read_file(event["savedPath"]), data)

            process.terminate()
            exit_code = process.wait(timeout=8)
            self.assertEqual(exit_code, 0)
            self.assertTrue(any(line.startswith("STOPPED") for line in output.lines))


class TestCliCommands(unittest.TestCase):
    def setUp(self):
        self._peer_ctx = running_peer(name="CLI 命令接收端", pairing_code=PAIR_CODE)
        self.peer, self.tmp = self._peer_ctx.__enter__()
        self.addCleanup(self._peer_ctx.__exit__, None, None, None)

    def test_pair_then_send_text_without_code(self):
        state_path = os.path.join(self.tmp, "cli-pair.json")
        common = [
            "--name",
            "CLI 配对端",
            "--state",
            state_path,
            "--host",
            "127.0.0.1",
            "--port",
            str(self.peer.port),
        ]
        exit_code, stdout = run_cli(REFERENCE_PEER, ["pair"] + common + ["--code", PAIR_CODE])
        self.assertEqual(exit_code, 0, stdout)
        self.assertIn("RESULT kind=ok", stdout)
        self.assertTrue(self.peer.is_paired(self._identity_of(state_path)))

        exit_code, stdout = run_cli(REFERENCE_PEER, ["send-text"] + common + ["--text", "CLI 中文 😀"])
        self.assertEqual(exit_code, 0, stdout)
        self.assertIn("RESULT kind=ok", stdout)
        self.assertEqual(self.peer.received_texts()[-1]["text"], "CLI 中文 😀")

        file_data = os.urandom(300000)
        file_path = make_file(self.tmp, "CLI 发送.bin", file_data)
        exit_code, stdout = run_cli(REFERENCE_PEER, ["send-file"] + common + ["--file", file_path])
        self.assertEqual(exit_code, 0, stdout)
        files = self.peer.received_files()
        self.assertEqual(files[-1]["originalName"], "CLI 发送.bin")
        self.assertEqual(files[-1]["sha256"], hashlib.sha256(file_data).hexdigest())
        self.assertEqual(read_file(files[-1]["savedPath"]), file_data)

    def test_wrong_code_exits_three(self):
        state_path = os.path.join(self.tmp, "cli-wrong.json")
        args = [
            "send-text",
            "--name",
            "CLI 错误码",
            "--state",
            state_path,
            "--host",
            "127.0.0.1",
            "--port",
            str(self.peer.port),
            "--code",
            "000000",
            "--text",
            "配对码错误",
        ]
        exit_code, stdout = run_cli(REFERENCE_PEER, args)
        self.assertEqual(exit_code, 3, stdout)
        self.assertIn("RESULT kind=need_pair", stdout)
        self.assertFalse(self.peer.is_paired(self._identity_of(state_path)))
        self.assertIn("CLI 错误码", self.peer.pending_pair_names().values())

    def test_send_text_by_discovered_peer_name(self):
        port = find_free_udp_port()
        peer_name = "可发现接收端 " + str(os.getpid())
        with running_peer(
            name=peer_name,
            enable_discovery=True,
            discovery_port=port,
            broadcast=True,
            announce_interval=0.5,
        ) as (discoverable, tmp):
            state_path = os.path.join(tmp, "cli-discover.json")
            args = [
                "send-text",
                "--name",
                "CLI 发现发送端",
                "--state",
                state_path,
                "--peer",
                peer_name,
                "--discovery-port",
                str(port),
                "--discovery-seconds",
                "6",
                "--code",
                PAIR_CODE,
                "--text",
                "通过发现发送的文字 🚀",
            ]
            exit_code, stdout = run_cli(REFERENCE_PEER, args)
            self.assertEqual(exit_code, 0, stdout)
            self.assertIn("TARGET", stdout)
            self.assertEqual(discoverable.received_texts()[-1]["text"], "通过发现发送的文字 🚀")

    def test_discover_subcommand_lists_peer(self):
        port = find_free_udp_port()
        peer_name = "发现列表接收端 " + str(os.getpid())
        with running_peer(
            name=peer_name,
            enable_discovery=True,
            discovery_port=port,
            broadcast=True,
            announce_interval=0.5,
        ) as (peer, tmp):
            exit_code, stdout = run_cli(
                REFERENCE_PEER, ["discover", "--seconds", "3", "--discovery-port", str(port)], timeout=20
            )
            self.assertEqual(exit_code, 0, stdout)
            expected_name = json.dumps(peer_name, ensure_ascii=False)
            self.assertIn("DISCOVERED", stdout)
            self.assertIn(expected_name, stdout)
            self.assertIn("port=%d" % peer.port, stdout)
            self.assertIn("DONE peers=", stdout)

    def _identity_of(self, state_path):
        with open(state_path, "r", encoding="utf-8") as handle:
            return json.load(handle)["id"]


# ---------------------------------------------------------------------------
# run_reference_peer.py 包装器
# ---------------------------------------------------------------------------


class TestRunReferencePeer(unittest.TestCase):
    def test_wrapper_receives_text_and_file(self):
        tmp = tempfile.mkdtemp(prefix="refpeer-wrapper-")
        self.addCleanup(shutil.rmtree, tmp, True)
        script_path = os.path.join(tmp, "receive.txt")
        with open(script_path, "w", encoding="utf-8") as handle:
            handle.write("list" + chr(10))
            handle.write("code" + chr(10))
            handle.write("wait 4" + chr(10))
            handle.write("received" + chr(10))
            handle.write("quit" + chr(10))
        receive_dir = os.path.join(tmp, "recv")
        args = [
            "--name",
            "包装器接收端 " + str(os.getpid()),
            "--code",
            PAIR_CODE,
            "--receive-dir",
            receive_dir,
            "--state",
            os.path.join(tmp, "state.json"),
            "--no-broadcast",
            "--script",
            script_path,
            "--seconds",
            "40",
        ]
        with running_cli(RUN_PEER, args, "run_reference_peer") as (process, output, info):
            self.assertEqual(info["code"], PAIR_CODE)
            text = "包装器收到：中文 😀"
            result = rp.send_text(
                "127.0.0.1", info["port"], text, "wrapper-client-1", "包装器测试手机", code=PAIR_CODE
            )
            self.assertTrue(result.ok, result)
            data = os.urandom(256000)
            path = make_file(tmp, "包装器文件.bin", data)
            result = rp.send_file("127.0.0.1", info["port"], path, "wrapper-client-1", "包装器测试手机")
            self.assertTrue(result.ok, result)
            event = wait_event(output, "text", timeout=8.0)
            self.assertEqual(event["text"], text)
            event = wait_event(output, "file", timeout=8.0)
            self.assertEqual(event["sha256"], hashlib.sha256(data).hexdigest())
            exit_code = process.wait(timeout=20)
            self.assertEqual(exit_code, 0)
            self.assertTrue(any(line.startswith("RECEIVED_TEXT") for line in output.lines))
            self.assertTrue(any(line.startswith("RECEIVED_FILE") for line in output.lines))
            self.assertTrue(any(line.startswith("CODE " + PAIR_CODE) for line in output.lines))

    def test_wrapper_pairs_and_sends_to_phone(self):
        discovery_port = find_free_udp_port()
        phone_name = "手机端-" + str(os.getpid())
        with running_peer(
            name=phone_name,
            enable_discovery=True,
            discovery_port=discovery_port,
            broadcast=True,
            announce_interval=0.5,
        ) as (phone, phone_tmp):
            tmp = tempfile.mkdtemp(prefix="refpeer-wrapper-send-")
            self.addCleanup(shutil.rmtree, tmp, True)
            data = os.urandom(180000)
            file_path = make_file(tmp, "电脑端发送.bin", data)
            script_path = os.path.join(tmp, "send.txt")
            lines = [
                "help",
                "wait-peer " + shlex.quote(phone_name) + " 20",
                "pair " + shlex.quote(phone_name) + " " + PAIR_CODE,
                "send-text " + shlex.quote(phone_name) + " 电脑端模拟器发来的中文 😀",
                "send-file " + shlex.quote(phone_name) + " " + shlex.quote(file_path),
                "list",
                "received",
                "quit",
            ]
            with open(script_path, "w", encoding="utf-8") as handle:
                handle.write(chr(10).join(lines) + chr(10))
            args = [
                "--name",
                "包装器发送端 " + str(os.getpid()),
                "--code",
                "112233",
                "--receive-dir",
                os.path.join(tmp, "recv"),
                "--state",
                os.path.join(tmp, "state.json"),
                "--discovery-port",
                str(discovery_port),
                "--script",
                script_path,
                "--seconds",
                "45",
            ]
            with running_cli(RUN_PEER, args, "run_reference_peer send") as (process, output, info):
                exit_code = process.wait(timeout=40)
                stdout = chr(10).join(output.lines)
                self.assertEqual(exit_code, 0, stdout)
                self.assertIn("PAIR kind=ok", stdout)
                self.assertGreaterEqual(stdout.count("SEND kind=ok"), 2)
                self.assertEqual(phone.received_texts()[-1]["text"], "电脑端模拟器发来的中文 😀")
                files = phone.received_files()
                self.assertEqual(files[-1]["originalName"], "电脑端发送.bin")
                self.assertEqual(files[-1]["sha256"], hashlib.sha256(data).hexdigest())
                self.assertEqual(read_file(files[-1]["savedPath"]), data)

    def test_wrapper_reports_unknown_command(self):
        tmp = tempfile.mkdtemp(prefix="refpeer-wrapper-err-")
        self.addCleanup(shutil.rmtree, tmp, True)
        script_path = os.path.join(tmp, "err.txt")
        with open(script_path, "w", encoding="utf-8") as handle:
            handle.write("bogus-command" + chr(10) + "quit" + chr(10))
        args = [
            "--name",
            "包装器错误测试",
            "--state",
            os.path.join(tmp, "state.json"),
            "--receive-dir",
            os.path.join(tmp, "recv"),
            "--no-broadcast",
            "--script",
            script_path,
            "--seconds",
            "20",
        ]
        exit_code, stdout = run_cli(RUN_PEER, args, timeout=25)
        self.assertEqual(exit_code, 1, stdout)
        self.assertIn("ERROR", stdout)
        self.assertIn("errors=1", stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
