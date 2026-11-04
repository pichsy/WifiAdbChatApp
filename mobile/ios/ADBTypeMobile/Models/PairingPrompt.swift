import Foundation

/// 配对弹窗状态。beforeSend 表示是首次发送触发的配对，配对成功后会自动重发内容。
struct PairingPrompt: Identifiable, Equatable {
    enum Mode: Equatable {
        case manual
        case beforeSend
    }

    let peerID: String
    let peerName: String
    let mode: Mode
    var errorText: String?
    var busy: Bool = false

    var id: String { peerID }

    var title: String { "与「\(peerName)」配对" }

    var message: String {
        switch mode {
        case .beforeSend:
            return "首次给「\(peerName)」发送，需要输入对方屏幕上显示的 6 位配对码"
        case .manual:
            return "输入对方屏幕上显示的 6 位配对码，配对成功后就能互发文字和文件"
        }
    }

    var confirmTitle: String {
        mode == .beforeSend ? "配对并发送" : "配对"
    }
}

/// 配对成功后需要自动补发的内容。
enum PendingSendBody {
    case text(String)
    case files([URL])
}
