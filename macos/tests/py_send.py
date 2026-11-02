#!/usr/bin/env python3
"""Python 发送端：发现 MacProbe 后按协议发一条文字 + 一个文件，用来验证 macOS 接收路径。"""
import argparse
import json
import os
import socket
import struct
import sys
import time

APPTAG = "ADBTypeLink"
DISCOVERY_PORT = 52730


def read_n(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise EOFError("closed")
        data += chunk
    return data


def read_frame(conn):
    header = read_n(conn, 4)
    length = struct.unpack(">I", header)[0]
    return json.loads(read_n(conn, length))


def send_json(conn, obj):
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    conn.sendall(struct.pack(">I", len(body)) + body)


def discover(name, timeout=12.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    sock.bind(("0.0.0.0", DISCOVERY_PORT))
    sock.settimeout(1.0)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(8192)
        except socket.timeout:
            continue
        try:
            obj = json.loads(data)
        except Exception:
            continue
        if obj.get("app") == APPTAG and obj.get("name") == name:
            return addr[0], int(obj["port"])
    raise RuntimeError(f"没有发现名为 {name} 的对端")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--peer-name", default="MacProbe")
    parser.add_argument("--host", default=None)
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--code", required=True)
    parser.add_argument("--text", default="你好，这是 Python 发来的测试消息 😀")
    parser.add_argument("--file", default=None)
    args = parser.parse_args()

    if args.host and args.port:
        host, port = args.host, args.port
        print(f"TARGET {args.peer_name} {host}:{port}", flush=True)
    else:
        host, port = discover(args.peer_name)
        print(f"DISCOVERED {args.peer_name} {host}:{port}", flush=True)

    conn = socket.create_connection((host, port), timeout=10)
    conn.settimeout(30)
    me = {"app": APPTAG, "v": 1, "id": "py-sender-" + str(os.getpid()), "name": "Python 发送端"}
    send_json(conn, {**me, "code": args.code})
    response = read_frame(conn)
    print("HANDSHAKE", response, flush=True)
    if response.get("type") != "hello_ok":
        print("FAILED: pairing", flush=True)
        return 1

    send_json(conn, {"type": "text", "text": args.text})
    ok = read_frame(conn)
    print("TEXT ACK", ok, flush=True)
    if ok.get("type") != "ok":
        return 1

    if args.file:
        size = os.path.getsize(args.file)
        send_json(conn, {"type": "file", "name": os.path.basename(args.file), "size": size})
        with open(args.file, "rb") as handle:
            while True:
                chunk = handle.read(256 * 1024)
                if not chunk:
                    break
                conn.sendall(chunk)
        ok = read_frame(conn)
        print("FILE ACK", ok, flush=True)
        if ok.get("type") != "ok":
            return 1

    send_json(conn, {"type": "bye"})
    print("DONE", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
