import SwiftUI
import UIKit

/// 主界面：本机配对码 + 已配对电脑 + 附近设备，点进任意电脑进入聊天。
struct RootView: View {
    @ObservedObject var model: LANModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LocalDeviceCard(model: model)
                }

                if let pendingName = model.pendingPairName {
                    Section {
                        PendingPairCard(model: model, peerName: pendingName)
                    }
                }

                if model.shouldShowLocalNetworkHelp {
                    Section {
                        NetworkHelpCard(model: model)
                    }
                }

                Section("已配对") {
                    if model.sortedFriends.isEmpty {
                        Text("还没有已配对的电脑。把上面的本机配对码告诉电脑，或在电脑端输入它显示的配对码完成配对。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.sortedFriends) { peer in
                            DeviceRow(model: model, peer: peer, paired: true)
                        }
                    }
                }

                Section("附近设备") {
                    if model.nearbyPeers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在搜索附近的电脑…").font(.footnote)
                            }
                            Text("请确认电脑端「文件互传助手」已打开，并且和手机连在同一个 Wi-Fi。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(model.nearbyPeers) { peer in
                            DeviceRow(model: model, peer: peer, paired: false)
                        }
                    }
                }

                Section {
                    StatusFooter(model: model)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("文件互传助手")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.refreshDiscovery()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新搜索")
                }
            }
            .navigationDestination(for: LANPeer.self) { peer in
                ChatView(model: model, initialPeer: peer)
            }
            .sheet(item: $model.pairingPrompt) { prompt in
                PairingSheet(model: model, prompt: prompt)
            }
        }
    }
}

/// 底部状态条：发现 / 收发的最近一次结果。
struct StatusFooter: View {
    @ObservedObject var model: LANModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(model.statusKind.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

/// 有电脑正在请求配对：把本机配对码告诉对方。
struct PendingPairCard: View {
    @ObservedObject var model: LANModel
    let peerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("「\(peerName)」正在请求配对", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            HStack(spacing: 10) {
                Text("本机配对码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.pairingCode)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .tracking(2)
                Spacer()
                Button("复制") {
                    model.copyPairingCode()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                Button("忽略") {
                    model.clearPendingPair()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
            Text("把它告诉对方（或直接输入对方屏幕上显示的配对码），配对成功后就能互发消息。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 本地网络权限 / 找不到设备时的引导。
struct NetworkHelpCard: View {
    @ObservedObject var model: LANModel

    private var blocked: Bool { model.localNetworkBlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(blocked ? "本地网络权限未开启" : "还没找到电脑？",
                  systemImage: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(blocked
                 ? "到 设置 → 隐私与安全性 → 本地网络 里允许「文件互传助手」，然后点「重新搜索」。"
                 : "请确认：手机和电脑连在同一个 Wi-Fi；已允许「本地网络」权限；电脑端「文件互传助手」已打开。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("打开设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)

                Button("重新搜索") {
                    model.refreshDiscovery()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}
