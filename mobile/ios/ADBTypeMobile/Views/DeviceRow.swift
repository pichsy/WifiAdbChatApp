import SwiftUI

/// 设备列表行：图标 + 名称 + 在线状态 / 配对徽标。
struct DeviceRow: View {
    @ObservedObject var model: LANModel
    let peer: LANPeer
    let paired: Bool

    private var current: LANPeer { model.peer(for: peer.id) ?? peer }
    private var online: Bool { model.isOnline(peer.id) }

    var body: some View {
        NavigationLink(value: current) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title3)
                    .foregroundStyle(online ? Color.accentColor : Color.secondary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(
                        (online ? Color.accentColor : Color.secondary).opacity(0.12)
                    ))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(current.displayName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if paired {
                            Text("已配对")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.12)))
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Circle()
                    .fill(online ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !paired {
                Button {
                    model.beginPairing(with: current)
                } label: {
                    Label("配对", systemImage: "number")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if !paired {
                Button {
                    model.beginPairing(with: current)
                } label: {
                    Label("配对…", systemImage: "number")
                }
            }
            if online {
                Button {
                    model.ping(peer: current)
                } label: {
                    Label("重新连接", systemImage: "arrow.clockwise")
                }
            }
            if paired {
                Button {
                    model.copyPairingCode()
                } label: {
                    Label("复制本机配对码", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var subtitle: String {
        if !online {
            return paired
                ? "离线 · 上次 \(Formatting.relativeTime(current.lastSeen))"
                : "离线"
        }
        if paired {
            if let last = model.lastMessage(for: peer.id) {
                return "在线 · \(Formatting.messagePreview(last))"
            }
            return "在线 · 已配对"
        }
        return "在线 · 未配对，首次发送需输入配对码"
    }
}
