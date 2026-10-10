import AppKit
import SwiftUI

// Keep the native input client alive across settings/preview refreshes. In
// particular, never assign its string while an input method owns marked text.
final class QuickTextView: NSTextView {
    var onCompositionEnded: (() -> Void)?
    override func unmarkText() {
        super.unmarkText()
        onCompositionEnded?()
    }
}

final class QuickTextEditorCoordinator: NSObject, NSTextViewDelegate {
    private(set) var value: String
    var onChange: (String) -> Void
    init(value: String, onChange: @escaping (String) -> Void) {
        self.value = value; self.onChange = onChange
    }
    func update(_ textView: NSTextView, value: String) {
        // A model echo must not reset selection, undo, or a live composition.
        guard value != self.value, !textView.hasMarkedText() else { return }
        self.value = value
        if textView.string != value { textView.string = value }
    }
    func publish(_ textView: NSTextView) {
        guard !textView.hasMarkedText(), textView.string != value else { return }
        value = textView.string
        onChange(value)
    }
    func textDidChange(_ notification: Notification) {
        if let textView = notification.object as? NSTextView { publish(textView) }
    }
    func textDidEndEditing(_ notification: Notification) {
        if let textView = notification.object as? NSTextView { publish(textView) }
    }
}

struct QuickTextEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    func makeCoordinator() -> QuickTextEditorCoordinator {
        QuickTextEditorCoordinator(value: text) { text = $0 }
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .textBackgroundColor
        let editor = QuickTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = .zero
        editor.string = text
        editor.delegate = context.coordinator
        editor.onCompositionEnded = { [weak editor, weak coordinator = context.coordinator] in
            if let editor { coordinator?.publish(editor) }
        }
        editor.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? QuickTextView else { return }
        context.coordinator.onChange = { text = $0 }
        editor.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.update(editor, value: text)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: QuickTextEditorCoordinator) {
        guard let editor = scroll.documentView as? QuickTextView else { return }
        editor.delegate = nil
        editor.onCompositionEnded = nil
    }
}

struct QuickTextDocument: Hashable {
    let target: WheelEditingTarget
    let slot: Int
}
