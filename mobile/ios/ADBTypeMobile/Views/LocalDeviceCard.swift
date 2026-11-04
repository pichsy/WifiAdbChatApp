import SwiftUI

/// 本机信息：设备名、6 位配对码（可复制 / 换一个）、接收目录、配对数量。
struct LocalDeviceCard: View {
    @ObservedObject var model: LANModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deviceName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("本机 · iPhone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("已配对 \(model.pairedCount) 台")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.serverReady ? "已上线" : "正在启动…")
                        .font(.caption2)
                        .foregroundStyle(model.serverReady ? .green : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("本机配对码")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text(model.pairingCode)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .textSelection(.enabled)
                        .accessibilityLabel("本机配对码 \(model.pairingCode)")

                    Spacer()

                    Button {
                        model.copyPairingCode()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("复制配对码")

                    Button {
                        model.regenerateCode()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("换一个配对码")
                }

                Text("在电脑端「文件互传助手」里输入这 6 位数字完成配对，之后直接互发文字和文件。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Label("接收文件：文件 App › 我的 iPhone › 文件互传助手 › Downloads",
                      systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("收到的图片和视频会额外保存到系统相册（首次会询问「仅添加照片」权限，不允许也不影响文件保存）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let receiving = model.receivingLabel {
                    Label(receiving, systemImage: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
