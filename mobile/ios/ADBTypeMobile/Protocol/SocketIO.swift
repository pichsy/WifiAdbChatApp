import Foundation
import Darwin

/// 基于 BSD socket 的阻塞读写工具：读满、写满、超时、抓对端地址。
enum SocketIO {
    /// 发起 TCP 连接；6 秒超时，失败返回 nil。
    static func connect(host: String, port: UInt16, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close(fd)
            return nil
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(max(1, timeout * 1000))
            let ready = poll(&descriptor, 1, milliseconds)
            guard ready > 0 else {
                close(fd)
                return nil
            }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)
            guard socketError == 0 else {
                close(fd)
                return nil
            }
        }

        _ = fcntl(fd, F_SETFL, flags)
        setIODeadline(fd, seconds: Int(LinkProtocol.ioTimeout))
        return fd
    }

    /// 已建立连接的读写超时（规格 §7：30 秒）。
    static func setIODeadline(_ fd: Int32, seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 循环读满 count 字节；EOF / 超时 / 错误返回 nil。
    static func readExactly(_ fd: Int32, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        var remaining = count
        while remaining > 0 {
            let want = min(remaining, buffer.count)
            let received: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return recv(fd, base, want, 0)
            }
            guard received > 0 else { return nil }
            data.append(contentsOf: buffer[0..<received])
            remaining -= received
        }
        return data
    }

    /// 读取一帧：4 字节大端长度 + 正文。长度非法时返回 nil（调用方应断开连接）。
    static func readFrame(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, count: 4),
              let length = FrameCodec.frameLength(fromHeader: header) else {
            return nil
        }
        return readExactly(fd, count: length)
    }

    /// 循环写满，处理部分写入。
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        var success = true
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let written = send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written <= 0 {
                    success = false
                    return
                }
                offset += written
            }
        }
        return success
    }

    static func writeJSON(_ fd: Int32, _ object: [String: Any]) -> Bool {
        guard let frame = FrameCodec.encode(object) else { return false }
        return writeAll(fd, frame)
    }

    /// 对端 IP（接收连接时用来补充好友记录）。
    static func remoteHost(_ fd: Int32) -> String {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &length)
            }
        }
        guard result == 0 else { return "" }
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var rawAddress = address.sin_addr
        inet_ntop(AF_INET, &rawAddress, &chars, socklen_t(INET_ADDRSTRLEN))
        return String(cString: chars)
    }
}
