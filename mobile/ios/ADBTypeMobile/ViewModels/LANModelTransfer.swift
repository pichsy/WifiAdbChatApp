import Foundation
import Darwin

/// 发送 / 接收扩展：握手、配对、文字、文件、服务端连接处理。
extension LANModel {
    enum HandshakeResult {
        case ok
        case needsPairing(String)
        case failure(String)
    }

    // MARK: - 主动配对

    func beginPairing(with peer: LANPeer) {
        guard !busy else {
            setStatus(.idle, "正在发送，等这次发送完成后再配对")
            return
        }
        guard peer.hasAddress else {
            setStatus(.failure, "「\(peer.displayName)」当前离线，等它上线后再配对")
            return
        }
        presentPairingPrompt(peer: peer, name: peer.displayName, mode: .manual, body: nil)
        setStatus(.idle, "输入「\(peer.displayName)」屏幕上显示的 6 位配对码")
    }

    func cancelPairing() {
        pairingPrompt = nil
        pendingPairBody = nil
        pairingPeerSnapshot = nil
        setStatus(.idle, "已取消配对")
    }

    /// 打开配对弹窗，同时记住对方当时的地址快照。失败重试时快照会保留。
    func presentPairingPrompt(peer: LANPeer,
                              name: String,
                              mode: PairingPrompt.Mode,
                              body: PendingSendBody?) {
        pairingPeerSnapshot = peer
        pendingPairBody = body
        pairingPrompt = PairingPrompt(peerID: peer.id, peerName: name, mode: mode)
    }

    func submitPairingCode(_ rawCode: String) {
        guard var prompt = pairingPrompt else { return }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy({ $0.isNumber }) else {
            prompt.errorText = "配对码是 6 位数字"
            prompt.busy = false
            pairingPrompt = prompt
            return
        }
        guard let peer = peer(for: prompt.peerID) ?? pairingPeerSnapshot else {
            prompt.errorText = "找不到这台电脑了，请回到列表重新选择"
            prompt.busy = false
            pairingPrompt = prompt
            return
        }
        prompt.errorText = nil
        prompt.busy = true
        pairingPrompt = prompt
        setStatus(.idle, "正在与「\(peer.displayName)」配对…")

        let body = pendingPairBody
        sendQueue.async { [weak self] in
            guard let self else { return }
            guard let fd = SocketIO.connect(host: peer.host,
                                            port: peer.port,
                                            timeout: LinkProtocol.connectTimeout) else {
                self.finishPairing(.failure("连不上「\(peer.displayName)」，请确认两台设备在同一局域网、对方应用已打开"),
                                   peer: peer,
                                   body: body)
                return
            }
            defer { close(fd) }
            switch self.handshake(fd, peer: peer, code: code) {
            case .ok:
                _ = SocketIO.writeJSON(fd, LinkMessages.bye())
                self.finishPairing(.ok, peer: peer, body: body)
            case .needsPairing:
                self.finishPairing(.failure("配对码不对，再看一眼对方屏幕上显示的数字"),
                                   peer: peer,
                                   body: body)
            case .failure(let message):
                self.finishPairing(.failure(message), peer: peer, body: body)
            }
        }
    }

    private func finishPairing(_ outcome: LANOutcome, peer: LANPeer, body: PendingSendBody?) {
        onMain { [weak self] in
            guard let self else { return }
            switch outcome {
            case .ok:
                self.pairingPrompt = nil
                self.pendingPairBody = nil
                self.pairingPeerSnapshot = nil
                self.setStatus(.success, "已与「\(peer.displayName)」配对，可以直接发送文字和文件")
                if let body {
                    if !self.beginPendingSend(body, to: peer) {
                        self.setStatus(.idle, "已配对，但刚才的内容没能自动重发，请再发一次")
                    }
                }
            case .needsPairing:
                break
            case .failure(let message):
                if var prompt = self.pairingPrompt {
                    prompt.busy = false
                    prompt.errorText = message
                    self.pairingPrompt = prompt
                }
                self.setStatus(.failure, message)
            }
        }
    }

    @discardableResult
    func beginPendingSend(_ body: PendingSendBody, to peer: LANPeer) -> Bool {
        guard !busy else { return false }
        switch body {
        case .text(let text):
            sendText(text, to: peer)
        case .files(let urls):
            sendFiles(urls, to: peer)
        }
        return true
    }

    // MARK: - 握手

    func handshake(_ fd: Int32, peer: LANPeer, code: String?) -> HandshakeResult {
        let hello = LinkMessages.hello(id: deviceID, name: deviceName, code: code)
        guard SocketIO.writeJSON(fd, hello),
              let data = SocketIO.readFrame(fd),
              let response = FrameCodec.decode(data),
              let type = response["type"] as? String else {
            return .failure("对方没有响应")
        }
        switch type {
        case "hello_ok":
            rememberPaired(peer.id)
            rememberFriend(peer: peer)
            return .ok
        case "pair_required":
            return .needsPairing(response["name"] as? String ?? peer.name)
        case "error":
            return .failure(response["message"] as? String ?? "对方拒绝了连接")
        default:
            return .failure("协议不匹配，请确认两端版本一致")
        }
    }

    // MARK: - 发送文字

    func sendText(_ rawText: String, to peer: LANPeer) {
        let text = rawText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus(.failure, "先输入要发送的文字")
            return
        }
        guard !busy else { return }
        guard peer.hasAddress else {
            setStatus(.failure, "「\(peer.displayName)」当前离线，等它上线后再发送")
            return
        }
        pendingPairBody = nil
        beginSend(label: "文字")
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.performText(text, peer: peer)
        }
    }

    private func performText(_ text: String, peer: LANPeer) {
        guard let fd = openConnection(to: peer, action: "发送") else { return }
        defer { close(fd) }

        switch handshake(fd, peer: peer, code: nil) {
        case .ok:
            guard SocketIO.writeJSON(fd, LinkMessages.text(text)),
                  let responseData = SocketIO.readFrame(fd),
                  let response = FrameCodec.decode(responseData),
                  response["type"] as? String == "ok" else {
                finishSendWithFailure("发送文字失败，对方没有确认", peer: peer)
                return
            }
            _ = SocketIO.writeJSON(fd, LinkMessages.bye())
            onMain { [weak self] in
                guard let self else { return }
                self.finishSend()
                self.appendMessage(LANMessage(direction: .outgoing,
                                              peerName: peer.name,
                                              text: text),
                                   peerID: peer.id)
                self.setStatus(.success, "已把文字发送给 \(peer.displayName)")
            }
        case .needsPairing(let name):
            onMain { [weak self] in
                guard let self else { return }
                self.finishSend()
                self.presentPairingPrompt(peer: peer, name: name, mode: .beforeSend, body: .text(text))
                self.setStatus(.idle, "首次给「\(name)」发送，需要输入对方屏幕上显示的 6 位配对码")
            }
        case .failure(let message):
            finishSendWithFailure(message, peer: peer)
        }
    }

    // MARK: - 发送文件

    func sendFiles(_ urls: [URL], to peer: LANPeer) {
        guard !urls.isEmpty else {
            setStatus(.failure, "先选择文件")
            return
        }
        guard !busy else { return }
        guard peer.hasAddress else {
            setStatus(.failure, "「\(peer.displayName)」当前离线，等它上线后再发送")
            return
        }
        pendingPairBody = nil
        beginSend(label: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件")
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.performFiles(urls, peer: peer)
        }
    }

    private func performFiles(_ urls: [URL], peer: LANPeer) {
        for (index, url) in urls.enumerated() {
            // fileImporter 返回的是安全作用域 URL：读之前申请访问，读完释放。
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }

            let size = fileSize(at: url)
            guard size > 0 else {
                finishSendWithFailure("读不到文件：\(url.lastPathComponent)", peer: peer)
                return
            }

            onMain { [weak self] in
                self?.updateSendLabel(urls.count > 1
                    ? "\(index + 1)/\(urls.count) \(url.lastPathComponent)"
                    : url.lastPathComponent)
                self?.updateSendProgress(urls.count > 1 ? Double(index) / Double(urls.count) : 0)
            }

            guard let fd = openConnection(to: peer, action: "发送文件") else { return }
            defer { close(fd) }

            let handshakeResult = handshake(fd, peer: peer, code: nil)
            switch handshakeResult {
            case .needsPairing(let name):
                let remaining = Array(urls[index...])
                onMain { [weak self] in
                    guard let self else { return }
                    self.finishSend()
                    self.presentPairingPrompt(peer: peer, name: name, mode: .beforeSend, body: .files(remaining))
                    self.setStatus(.idle, "首次给「\(name)」发送，需要输入对方屏幕上显示的 6 位配对码")
                }
                return
            case .failure(let message):
                finishSendWithFailure(message, peer: peer)
                return
            case .ok:
                break
            }

            guard SocketIO.writeJSON(fd, LinkMessages.file(name: url.lastPathComponent, size: size)) else {
                finishSendWithFailure("发送文件信息失败", peer: peer)
                return
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                finishSendWithFailure("读不到文件：\(url.lastPathComponent)", peer: peer)
                return
            }

            var sentBytes = 0
            var failed = false
            while true {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: LinkProtocol.fileChunkBytes)
                } catch {
                    failed = true
                    break
                }
                guard let chunk, !chunk.isEmpty else { break }
                guard SocketIO.writeAll(fd, chunk) else {
                    failed = true
                    break
                }
                sentBytes += chunk.count
                let fraction = Double(sentBytes) / Double(size)
                let overall = (Double(index) + fraction) / Double(urls.count)
                updateSendProgress(min(0.99, overall))
            }
            try? handle.close()

            if failed {
                finishSendWithFailure("网络中断，文件没发完", peer: peer)
                return
            }

            guard let responseData = SocketIO.readFrame(fd),
                  let response = FrameCodec.decode(responseData),
                  response["type"] as? String == "ok" else {
                finishSendWithFailure("对方没有确认收到文件", peer: peer)
                return
            }
            _ = SocketIO.writeJSON(fd, LinkMessages.bye())

            // 每个文件成功就立刻记进聊天记录：中途失败时已经发出去的文件也留痕。
            onMain { [weak self] in
                self?.appendMessage(LANMessage(direction: .outgoing,
                                               peerName: peer.name,
                                               fileURL: url,
                                               fileSize: size),
                                    peerID: peer.id)
            }
        }

        onMain { [weak self] in
            guard let self else { return }
            self.finishSend()
            let message = urls.count == 1
                ? "已把「\(urls[0].lastPathComponent)」发送给 \(peer.displayName)"
                : "已把 \(urls.count) 个文件发送给 \(peer.displayName)"
            self.setStatus(.success, message)
        }
    }

    private func fileSize(at url: URL) -> Int {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return size
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func openConnection(to peer: LANPeer, action: String) -> Int32? {
        guard peer.hasAddress else {
            onMain { [weak self] in
                self?.finishSend()
                self?.setStatus(.failure, "「\(peer.displayName)」的地址未知，等它重新上线后再\(action)")
            }
            return nil
        }
        if let fd = SocketIO.connect(host: peer.host,
                                     port: peer.port,
                                     timeout: LinkProtocol.connectTimeout) {
            return fd
        }
        triggerHeartbeat(toHost: peer.host)
        onMain { [weak self] in
            self?.finishSend()
            self?.setStatus(.failure,
                            "连不上「\(peer.displayName)」，请确认两台设备在同一局域网、对方应用已打开")
        }
        return nil
    }

    private func finishSendWithFailure(_ message: String, peer: LANPeer) {
        onMain { [weak self] in
            self?.finishSend()
            self?.setStatus(.failure, message)
        }
    }

    // MARK: - 服务端：接收连接

    func handleClient(_ fd: Int32) {
        defer { close(fd) }
        SocketIO.setIODeadline(fd, seconds: Int(LinkProtocol.ioTimeout))

        guard let helloData = SocketIO.readFrame(fd),
              let hello = FrameCodec.decode(helloData),
              hello["app"] as? String == LinkProtocol.appTag,
              let peerID = hello["id"] as? String,
              peerID != deviceID,
              let peerName = hello["name"] as? String,
              !peerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = SocketIO.writeJSON(fd, LinkMessages.error("协议不匹配，请升级两端应用"))
            return
        }

        let auth = authSnapshot()
        if !auth.paired.contains(peerID) {
            let code = (hello["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let code, code == auth.code else {
                setPendingPair(name: peerName, peerID: peerID)
                setStatus(.idle, "「\(peerName)」正在请求配对，把本机配对码 \(pairingCode) 告诉对方")
                _ = SocketIO.writeJSON(fd, LinkMessages.pairRequired(name: deviceName))
                return
            }
            rememberPaired(peerID)
        }

        // 对方主动连过来时也刷新好友记录（端口未知，等对方广播时补全）。
        rememberFriend(id: peerID, name: peerName, host: SocketIO.remoteHost(fd), port: 0)

        guard SocketIO.writeJSON(fd, LinkMessages.helloOk(name: deviceName, id: deviceID)) else {
            return
        }
        setStatus(.idle, "\(peerName) 已连接")

        while true {
            guard let frame = SocketIO.readFrame(fd),
                  let object = FrameCodec.decode(frame),
                  let type = object["type"] as? String else {
                return
            }

            switch type {
            case "text":
                guard let text = object["text"] as? String else { return }
                appendMessage(LANMessage(direction: .incoming, peerName: peerName, text: text),
                              peerID: peerID)
                setStatus(.success, "收到 \(peerName) 发来的文字")
                guard SocketIO.writeJSON(fd, LinkMessages.ok()) else { return }

            case "file":
                guard let rawName = object["name"] as? String,
                      let size = object["size"] as? Int,
                      size >= 0 else {
                    return
                }
                setReceivingLabel("正在接收「\(rawName)」…")
                setStatus(.idle, "正在接收 \(peerName) 发来的「\(rawName)」…")
                guard let url = receiveFile(fd, rawName: rawName, size: size) else {
                    setReceivingLabel(nil)
                    _ = SocketIO.writeJSON(fd, LinkMessages.error("保存文件失败"))
                    return
                }
                setReceivingLabel(nil)
                appendMessage(LANMessage(direction: .incoming,
                                         peerName: peerName,
                                         fileURL: url,
                                         fileSize: size),
                              peerID: peerID)
                let savedName = url.lastPathComponent
                setStatus(.success, "已收到「\(savedName)」，已保存到「文件」App 的「文件互传助手/Downloads」")
                // 图片 / 视频额外存到系统相册；失败不影响 Documents/Downloads 里的文件。
                PhotoLibrarySaver.saveToPhotoLibrary(url) { [weak self] outcome in
                    guard let self, outcome == .saved else { return }
                    self.setStatus(.success, "已收到「\(savedName)」，已保存到「文件」App 的「文件互传助手/Downloads」，并已存入系统相册")
                }
                guard SocketIO.writeJSON(fd, LinkMessages.ok()) else { return }

            case "bye":
                return

            default:
                return
            }
        }
    }

    /// 接收文件：只取安全文件名、重名自动编号、失败清理半截文件（规格 §6）。
    private func receiveFile(_ fd: Int32, rawName: String, size: Int) -> URL? {
        guard let safeName = ReceivedFileNaming.sanitizedFileName(rawName) else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: receiveDirectory, withIntermediateDirectories: true)

        let url = ReceivedFileNaming.uniqueDestination(in: receiveDirectory, fileName: safeName)
        guard manager.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }

        var remaining = size
        while remaining > 0 {
            let want = min(LinkProtocol.fileChunkBytes, remaining)
            guard let chunk = SocketIO.readExactly(fd, count: want) else {
                try? handle.close()
                try? manager.removeItem(at: url)
                return nil
            }
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                try? handle.close()
                try? manager.removeItem(at: url)
                return nil
            }
            remaining -= chunk.count
        }
        try? handle.close()
        return url
    }
}
