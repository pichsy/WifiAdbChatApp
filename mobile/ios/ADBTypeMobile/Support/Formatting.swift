import Foundation

/// 界面上的时间 / 文件大小格式化。
enum Formatting {
    private static let bubbleTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func bubbleTime(_ date: Date) -> String {
        bubbleTimeFormatter.string(from: date)
    }

    static func relativeTime(_ date: Date) -> String {
        guard date != .distantPast else { return "未知" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func rowTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return bubbleTimeFormatter.string(from: date)
        }
        return dayTimeFormatter.string(from: date)
    }

    static func fileSize(_ bytes: Int?) -> String {
        let value = Int64(max(0, bytes ?? 0))
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func messagePreview(_ message: LANMessage) -> String {
        switch message.kind {
        case .text:
            return message.text ?? ""
        case .file:
            return "[文件] \(message.fileName ?? "文件")"
        }
    }
}
