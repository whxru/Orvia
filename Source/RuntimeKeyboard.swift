import AppKit
import SwiftUI

private final class InputKeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class RuntimeKeyboardController: NSObject, NSWindowDelegate, ObservableObject {
    private let sender: KeySender
    private var panel: NSPanel?
    @Published private(set) var modifiers = Set<UInt16>()
    var isVisible: Bool { panel?.isVisible == true }
    init(sender: KeySender) { self.sender = sender }
    func show(language: AppLanguage) {
        modifiers.removeAll()
        if panel == nil {
            let panel = InputKeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 390),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .floating
            panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self; self.panel = panel
        }
        guard let panel else { return }
        panel.title = language.text("虚拟键盘")
        panel.contentView = NSHostingView(rootView: RuntimeKeyboardView(controller: self, language: language))
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 20))
            }
        }
        // Keep the destination's field focused while buttons in this panel are clicked.
        panel.orderFrontRegardless()
    }
    func press(_ code: UInt16) {
        if VirtualKeyboardSelection.modifierCodes.contains(code) {
            if !modifiers.insert(code).inserted { modifiers.remove(code) }
            return
        }
        let flags = modifiers.reduce(UInt64(0)) { $0 | (RecordedKey.modifierInfo[$1]?.0 ?? 0) }
        let recorded = RecordedKey.capture(key: code, flags: CGEventFlags(rawValue: flags))
        sender.tap(KeyAction.find(recorded.storedValue))
        modifiers.removeAll()
    }
    func clearModifiers() { modifiers.removeAll() }
    func windowWillClose(_ notification: Notification) { modifiers.removeAll() }
}

private struct RuntimeKeyboardView: View {
    @ObservedObject var controller: RuntimeKeyboardController
    let language: AppLanguage
    @State private var extended = false
    private func l(_ text: String) -> String { language.text(text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l("点击按键直接输入到当前应用；修饰键选中后，与下一个按键组合。"))
                .font(.callout).foregroundColor(.secondary)
            HStack {
                Picker(l("键盘区域"), selection: $extended) {
                    Text(l("主键盘")).tag(false)
                    Text(l("数字键盘与扩展")).tag(true)
                }.pickerStyle(.segmented).frame(width: 310)
                Spacer()
                Button(l("清除修饰键")) { controller.clearModifiers() }.disabled(controller.modifiers.isEmpty)
            }
            VStack(spacing: 6) {
                if extended {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(spacing: 6) {
                            row([71,81,75,67].map { KeyboardKey(UInt16($0)) })
                            row([89,91,92,78].map { KeyboardKey(UInt16($0)) })
                            row([86,87,88,69].map { KeyboardKey(UInt16($0)) })
                            row([83,84,85,76].map { KeyboardKey(UInt16($0)) })
                            row([KeyboardKey(82,2),KeyboardKey(65)])
                        }.frame(width: 280)
                        VStack(spacing: 6) {
                            row([114,115,116,117,119,121].map { KeyboardKey(UInt16($0)) })
                            row([105,107,113,106].map { KeyboardKey(UInt16($0)) })
                            row([64,79,80,90].map { KeyboardKey(UInt16($0)) })
                            row([59,58,56,55,63].map { KeyboardKey(UInt16($0)) })
                        }
                    }.frame(height: 280)
                } else {
                    ForEach(KeyboardLayout.rows.indices, id: \.self) { index in
                        row(KeyboardLayout.rows[index], height: index == 0 ? 28 : 40)
                    }
                }
                HStack {
                    Spacer()
                    row([123,125,126,124].map { KeyboardKey(UInt16($0)) }, height: 28).frame(width: 210)
                }
            }
        }.padding(18).frame(width: 800).tint(.primary)
    }
    private func row(_ keys: [KeyboardKey], height: CGFloat = 40) -> some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width - CGFloat(keys.count - 1) * 5) / keys.reduce(0) { $0 + $1.width }
            HStack(spacing: 5) {
                ForEach(keys) { key in
                    let chosen = controller.modifiers.contains(key.code)
                    Button { controller.press(key.code) } label: {
                        Text(language.keyLabel(key.title)).font(.system(size: 11, weight: chosen ? .semibold : .regular))
                            .multilineTextAlignment(.center).lineLimit(2)
                            .frame(width: max(0, unit * key.width), height: height)
                            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.primary.opacity(0.2) : Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(chosen ? 0.5 : 0.15)))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(language.keyLabel(RecordedKey.capture(key: key.code, flags: []).label))
                        .accessibilityValue(chosen ? l("已选中") : l("未选中"))
                }
            }
        }.frame(height: height)
    }
}
