import SwiftUI
import UIKit

/// 输入对方 6 位配对码的弹窗。配对成功后由 LANModel 关闭，并在需要时自动重发内容。
struct PairingSheet: View {
    @ObservedObject var model: LANModel
    let prompt: PairingPrompt

    @State private var code = ""
    @FocusState private var focused: Bool

    private var errorText: String? { model.pairingPrompt?.errorText }
    private var isBusy: Bool { model.pairingPrompt?.busy == true }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(prompt.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemBackground)))
                    .focused($focused)
                    .disabled(isBusy)
                    .onChange(of: code) { _, newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(6))
                        if digits != newValue {
                            code = digits
                        }
                    }
                    .accessibilityLabel("对方屏幕上的 6 位配对码")

                HStack(spacing: 14) {
                    Button {
                        pasteCode()
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)

                    if isBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在配对…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .font(.footnote)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("配对码显示在对方电脑「文件互传助手」的左下角，输入一次以后就不用再输了。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle(prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        model.cancelPairing()
                    }
                    .disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(prompt.confirmTitle) {
                        focused = false
                        model.submitPairingCode(code)
                    }
                    .disabled(isBusy || code.count != 6)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    focused = true
                }
            }
            .interactiveDismissDisabled()
        }
    }

    private func pasteCode() {
        guard let text = UIPasteboard.general.string else { return }
        code = String(text.filter(\.isNumber).prefix(6))
    }
}
