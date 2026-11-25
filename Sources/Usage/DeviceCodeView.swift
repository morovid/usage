import AppKit
import SwiftUI

struct DeviceCodeView: View {
    let code: String
    @State private var copied = false
    @State private var copyCount = 0

    init(code: String, initiallyCopied: Bool = false) {
        self.code = code
        _copied = State(initialValue: initiallyCopied)
        _copyCount = State(initialValue: initiallyCopied ? 1 : 0)
    }

    var body: some View {
        SelectableDeviceCode(code: code) {
            copied = true
            copyCount += 1
        }
        .frame(width: 240, height: 38)
        .overlay(alignment: .top) {
            if copied {
                Text("Copied")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.1)))
                    .offset(y: -32)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            copied = false
        }
    }
}

private struct SelectableDeviceCode: NSViewRepresentable {
    let code: String
    var onCopy: () -> Void

    func makeNSView(context: Context) -> CopyableCodeField {
        let field = CopyableCodeField(frame: .zero)
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        field.setAccessibilityLabel("GitHub sign-in code")
        field.setAccessibilityHelp("Click to select the whole code and copy it to the clipboard.")
        return field
    }

    func updateNSView(_ field: CopyableCodeField, context: Context) {
        // Avoid resetting the field editor's selection when the Copied hint updates.
        if field.stringValue != code { field.stringValue = code }
        field.onCopy = onCopy
    }
}

private final class CopyableCodeField: NSTextField {
    var onCopy: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        selectAndCopy()
    }

    override func accessibilityPerformPress() -> Bool {
        selectAndCopy()
        return true
    }

    private func selectAndCopy() {
        selectText(nil)
        currentEditor()?.selectAll(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stringValue, forType: .string)
        onCopy?()
    }
}
