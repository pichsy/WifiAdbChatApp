import Foundation

/// 接收文件时的文件名清洗与重名编号（规格 §6）。
enum ReceivedFileNaming {
    /// 只取路径最后一段（同时处理 "/" 和 "\\"），拒绝空名、"."、".."。
    static func sanitizedFileName(_ rawName: String) -> String? {
        let lastComponent = rawName
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let trimmed = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }

    /// 在目录里找一个不冲突的文件名：base (2).ext、base (3).ext……
    static func uniqueDestination(in directory: URL,
                                  fileName: String,
                                  fileManager: FileManager = .default) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = fileName
        var index = 2
        var url = directory.appendingPathComponent(candidate)
        while fileManager.fileExists(atPath: url.path) {
            candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            url = directory.appendingPathComponent(candidate)
            index += 1
        }
        return url
    }
}
