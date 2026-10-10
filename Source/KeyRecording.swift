import AppKit
import Carbon

struct RecordedKey: Codable, Equatable {
    static let functionKeyCodes: Set<UInt16> = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
    let key: UInt16
    let flags: UInt64
    let label: String
    let modifier: Bool
    var storedValue: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "recorded:" + (try! encoder.encode(self)).base64EncodedString()
    }
    static func decode(_ value: String) -> Self? {
        guard value.hasPrefix("recorded:"), let data = Data(base64Encoded: String(value.dropFirst(9))),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.key < 128, !value.label.isEmpty else { return nil }
        return value
    }
    static let manualKeyCodes: [UInt16] = Array(0...9) + [11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,53,54,55,56,57,58,59,60,61,62,63,64,65,67,69,71,75,76,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,96,97,98,99,100,101,103,105,106,107,109,111,113,114,115,116,117,118,119,120,121,122,123,124,125,126]
    static let modifierInfo: [UInt16: (UInt64, String)] = [
        54:(CGEventFlags.maskCommand.rawValue | 0x10,"右 Command"),55:(CGEventFlags.maskCommand.rawValue | 0x08,"左 Command"),
        56:(CGEventFlags.maskShift.rawValue | 0x02,"左 Shift"),60:(CGEventFlags.maskShift.rawValue | 0x04,"右 Shift"),
        58:(CGEventFlags.maskAlternate.rawValue | 0x20,"左 Option"),61:(CGEventFlags.maskAlternate.rawValue | 0x40,"右 Option"),
        59:(CGEventFlags.maskControl.rawValue | 0x01,"左 Control"),62:(CGEventFlags.maskControl.rawValue | 0x2000,"右 Control"),
        63:(CGEventFlags.maskSecondaryFn.rawValue,"Fn"),57:(CGEventFlags.maskAlphaShift.rawValue,"Caps Lock")]
    static func capture(key: UInt16, flags: CGEventFlags, characters: String? = nil) -> Self {
        let allowed: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        let clean = flags.intersection(allowed)
        if let (side, name) = modifierInfo[key] {
            var label = ""
            for (flag, glyph) in [(CGEventFlags.maskControl,"⌃"),(.maskAlternate,"⌥"),(.maskShift,"⇧"),(.maskCommand,"⌘"),(.maskSecondaryFn,"Fn ")] {
                if clean.contains(flag) && side & flag.rawValue == 0 { label += glyph }
            }
            return Self(key: key, flags: clean.rawValue | side, label: label + name, modifier: true)
        }
        let names: [UInt16:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"回车",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"空格",50:"`",51:"退格",53:"Esc",65:"小数点",67:"*",69:"+",71:"Clear",75:"/",76:"数字回车",78:"−",81:"=",82:"0",83:"1",84:"2",85:"3",86:"4",87:"5",88:"6",89:"7",91:"8",92:"9",115:"Home",116:"Page Up",117:"Delete",119:"End",121:"Page Down",123:"←",124:"→",125:"↓",126:"↑",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        var label = ""
        for (flag, glyph) in [(CGEventFlags.maskControl,"⌃"),(.maskAlternate,"⌥"),(.maskShift,"⇧"),(.maskCommand,"⌘"),(.maskSecondaryFn,"Fn ")] { if clean.contains(flag) { label += glyph } }
        label += names[key] ?? characters?.uppercased() ?? "键 \(key)"
        return Self(key: key, flags: clean.rawValue, label: label, modifier: false)
    }
}

final class KeyRecorderButton: NSButton {
    static weak var active: KeyRecorderButton?
    var language: AppLanguage = .chinese
    var bindingTitle = "" { didSet { if !recording { title = bindingTitle.isEmpty ? language.text("点击录制按键") : bindingTitle } } }
    var onRecord: ((String) -> Void)?
    private(set) var recording = false
    private var pending: RecordedKey?
    private var hotKeyMode: UnsafeMutableRawPointer?
    private var monitor: Any?
    private var focusObservers: [NSObjectProtocol] = []
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool { stop(); return super.resignFirstResponder() }
    @objc func beginRecording() {
        Self.active?.stop(); window?.makeFirstResponder(self)
        recording = true; pending = nil; Self.active = self
        hotKeyMode = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabledExceptUniversalAccess))
        title = language.text("请按单键或组合键…")
        for (name, object) in [(NSApplication.didResignActiveNotification, NSApp as AnyObject?), (NSWindow.didResignKeyNotification, window as AnyObject?), (NSWindow.willCloseNotification, window as AnyObject?)] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.stop() })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stop() }
                return event
            }
            guard let cg = event.cgEvent, self.consume(type: event.type == .keyDown ? .keyDown : .flagsChanged, event: cg) else { return event }
            return nil
        }
    }
    func stop() {
        recording = false; pending = nil
        if let hotKeyMode { PopSymbolicHotKeyMode(hotKeyMode); self.hotKeyMode = nil }
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }; focusObservers.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if Self.active === self { Self.active = nil }
        title = bindingTitle.isEmpty ? language.text("点击录制按键") : bindingTitle
    }
    func consume(type: CGEventType, event: CGEvent) -> Bool {
        guard recording, window?.isKeyWindow == true, NSApp.isActive else { stop(); return false }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown {
            let value = RecordedKey.capture(key: key, flags: event.flags)
            stop(); onRecord?(value.storedValue); return true
        }
        guard type == .flagsChanged else { return false }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn, .maskAlphaShift]
        if event.flags.intersection(relevant).isEmpty {
            if let value = pending { stop(); onRecord?(value.storedValue) }
        } else if let (flag, _) = RecordedKey.modifierInfo[key], event.flags.rawValue & flag != 0 {
            pending = RecordedKey.capture(key: key, flags: event.flags)
            title = language.keyLabel(pending?.label ?? "修饰键") + language.text(" · 松开以保存")
        }
        return true
    }
    deinit { if let hotKeyMode { PopSymbolicHotKeyMode(hotKeyMode) }; if let monitor { NSEvent.removeMonitor(monitor) }; for observer in focusObservers { NotificationCenter.default.removeObserver(observer) } }
}

final class KeyBindingControl: NSView {
    let recorder = KeyRecorderButton()
    let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    var onEdit: ((String, Bool) -> Void)?
    var onKeyboard: (() -> Void)?
    init() {
        super.init(frame: .zero)
        recorder.focusRingType = .none; recorder.bezelStyle = .rounded; recorder.alignment = .left; recorder.font = .systemFont(ofSize: 13)
        recorder.target = recorder; recorder.action = #selector(KeyRecorderButton.beginRecording)
        recorder.setAccessibilityLabel("录制按键")
        recorder.onRecord = { [weak self] in self?.onEdit?($0, false) }
        presets.bezelStyle = .rounded; presets.setAccessibilityLabel("预定义动作")
        presets.target = self; presets.action = #selector(selectPreset)
        addSubview(recorder); addSubview(presets)
        configure(language: .chinese, textMode: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        recorder.frame = NSRect(x: 0, y: 0, width: max(0,bounds.width-27), height: bounds.height)
        presets.frame = NSRect(x: bounds.width-28, y: 0, width: 28, height: bounds.height)
    }
    private var configuredLanguage: AppLanguage?
    func configure(language: AppLanguage, textMode: Bool) {
        recorder.language = language
        recorder.isEnabled = !textMode
        guard configuredLanguage != language else { return }
        configuredLanguage = language
        recorder.setAccessibilityLabel(language.text("录制按键"))
        presets.setAccessibilityLabel(language.text("预定义动作"))
        presets.removeAllItems(); presets.addItem(withTitle: "")
        for action in KeyAction.suggestions {
            presets.addItem(withTitle: language.text(action.label))
            presets.lastItem?.representedObject = action.id
        }
        presets.menu?.autoenablesItems = false
        presets.menu?.addItem(.separator())
        for (id, title, symbol) in [
            ("virtualKeyboard", "打开虚拟键盘", "keyboard"),
            ("clearText", "清空文本框", "xmark.circle"),
            ("text:", "快捷输入文字", "text.bubble")
        ] {
            presets.addItem(withTitle: language.text(title))
            presets.lastItem?.representedObject = id
            presets.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: language.text(title))?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        }
        presets.menu?.addItem(.separator())
        presets.addItem(withTitle: language.text("手动配置按键…"))
        presets.lastItem?.representedObject = "editor:keyboard"
        presets.lastItem?.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: nil)
    }
    @objc func selectPreset() {
        recorder.stop()
        guard let value = presets.selectedItem?.representedObject as? String else { return }
        switch value {
        case "editor:keyboard": onKeyboard?()
        default: onEdit?(value == "text:" ? "" : value, value == "text:")
        }
    }
}

// The virtual keyboard uses the same stored key format as hardware recording.
// Modifiers latch, while a second click on the main key removes it, allowing
// modifier-only bindings without generating any real keyboard events.
struct VirtualKeyboardSelection {
    private(set) var key: UInt16?
    private(set) var modifiers: [UInt16] = []
    static let modifierCodes: Set<UInt16> = [54,55,56,58,59,60,61,62,63]
    init(action: KeyAction) {
        guard action.canHold else { return }
        if !Self.modifierCodes.contains(action.key) { key = action.key }
        for (left, right, mask) in [(UInt16(55), UInt16(54), CGEventFlags.maskCommand), (58,61,.maskAlternate), (59,62,.maskControl), (56,60,.maskShift)] {
            guard action.flags.contains(mask) else { continue }
            let leftSide = RecordedKey.modifierInfo[left]!.0 & ~mask.rawValue
            let rightSide = RecordedKey.modifierInfo[right]!.0 & ~mask.rawValue
            if action.flags.rawValue & rightSide != 0 { modifiers.append(right) }
            if action.flags.rawValue & leftSide != 0 || action.flags.rawValue & (leftSide | rightSide) == 0 { modifiers.append(left) }
        }
        if action.flags.contains(.maskSecondaryFn) { modifiers.append(63) }
        if Self.modifierCodes.contains(action.key) {
            modifiers.removeAll { $0 == action.key }; modifiers.append(action.key)
        }
    }
    mutating func select(_ code: UInt16) {
        if Self.modifierCodes.contains(code) {
            if modifiers.contains(code) { modifiers.removeAll { $0 == code } }
            else { modifiers.append(code) }
        } else { key = key == code ? nil : code }
    }
    mutating func clear() { key = nil; modifiers = [] }
    func contains(_ code: UInt16) -> Bool { key == code || modifiers.contains(code) }
    var recorded: RecordedKey? {
        guard let code = key ?? modifiers.last else { return nil }
        let flags = modifiers.reduce(UInt64(0)) { $0 | (RecordedKey.modifierInfo[$1]?.0 ?? 0) }
        let captured = RecordedKey.capture(key: code, flags: CGEventFlags(rawValue: flags))
        return RecordedKey(key: captured.key, flags: captured.flags | flags, label: captured.label, modifier: captured.modifier)
    }
}
