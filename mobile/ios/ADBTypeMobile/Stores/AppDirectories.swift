import Foundation

/// App 本地数据目录：
/// - Application Support 存配对 / 好友 / 聊天；
/// - Documents/Downloads 存收到的文件（用户可在系统「文件」App 里看到）。
enum AppDirectories {
    static let appFolderName = "ADBTypeMobile"
    /// 收到文件的目录名（出现在「文件」App：我的 iPhone › 文件互传助手 › Downloads）。
    static let downloadsFolderName = "Downloads"
    /// 旧版本接收目录名（Documents/Received），启动时会自动迁移到 Downloads。
    static let legacyReceivedFolderName = "Received"

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    static var chatsDirectory: URL {
        supportDirectory.appendingPathComponent("chats", isDirectory: true)
    }

    /// 收到文件的保存目录：Documents/Downloads。
    /// Info.plist 已打开 UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace，
    /// 用户能在「文件」App 里直接看到和打开。
    static var receivedDirectory: URL {
        documentsDirectory.appendingPathComponent(downloadsFolderName, isDirectory: true)
    }

    /// 旧版本目录：Documents/Received，仅用于兼容 / 迁移。
    static var legacyReceivedDirectory: URL {
        documentsDirectory.appendingPathComponent(legacyReceivedFolderName, isDirectory: true)
    }

    static func ensureDirectories(fileManager: FileManager = .default) {
        for directory in [supportDirectory, chatsDirectory, receivedDirectory] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// 把旧版本 Documents/Received 里的文件迁移到 Documents/Downloads。
    /// - 返回「旧文件名 → 新文件名」映射（重名时新文件会自动编号），供聊天记录里的旧 filePath 修正。
    /// - 迁移失败的文件保持原样，不会丢文件；旧目录为空时删除，避免「文件」App 里残留空文件夹。
    @discardableResult
    static func migrateLegacyReceivedFiles(fileManager: FileManager = .default,
                                           legacyDirectory: URL = AppDirectories.legacyReceivedDirectory,
                                           destination: URL = AppDirectories.receivedDirectory) -> [String: String] {
        var mapping: [String: String] = [:]
        let legacyPath = legacyDirectory.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard legacyPath != destinationPath,
              let names = try? fileManager.contentsOfDirectory(atPath: legacyPath),
              !names.isEmpty else {
            return mapping
        }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for name in names {
            let source = legacyDirectory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            let target = ReceivedFileNaming.uniqueDestination(in: destination,
                                                              fileName: name,
                                                              fileManager: fileManager)
            do {
                try fileManager.moveItem(at: source, to: target)
                mapping[name] = target.lastPathComponent
            } catch {
                // 跨卷等极少见情况：退化成复制 + 删除，仍然保证文件落到 Downloads。
                if (try? fileManager.copyItem(at: source, to: target)) != nil {
                    try? fileManager.removeItem(at: source)
                    mapping[name] = target.lastPathComponent
                }
            }
        }

        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacyPath), remaining.isEmpty {
            try? fileManager.removeItem(at: legacyDirectory)
        }
        return mapping
    }
}
