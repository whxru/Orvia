import AppKit
import SwiftUI
import ApplicationServices

enum WheelTheme: String, Codable, CaseIterable, Identifiable {
    case minimal, glass
    // Retired themes remain readable in local preferences and v1 exports.
    static func restored(_ value: String) -> WheelTheme? {
        if ["frosted", "gta", "cyberpunk", "colorful"].contains(value) { return .glass }
        return WheelTheme(rawValue: value)
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let theme = Self.restored(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown wheel theme")
        }
        self = theme
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: return "简约"
        case .glass: return "液态玻璃"
        }
    }
    var detail: String {
        switch self {
        case .minimal: return "哑光底面，轻浮雕反馈"
        case .glass: return "通透折射，柔和透镜动效"
        }
    }
}

enum AppOperation { case settings, clearText, virtualKeyboard }

enum TriggerMode: String, Codable, CaseIterable, Identifiable {
    case onEntry, onRelease, whileInside
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onEntry: return "移入触发"
        case .onRelease: return "松手退出时触发"
        case .whileInside: return "移入按住，移出释放"
        }
    }
    var detail: String {
        switch self {
        case .onEntry: return "选中后执行一次；移出再移入可再次执行。"
        case .onRelease: return "松手退出轮盘时，执行最后选中的这一项；取消手势不执行。"
        case .whileInside: return "选中时按下，移出、回到中心或退出时释放。"
        }
    }
}

enum WheelFeedback: Equatable { case idle, selecting, holding, releaseReady, fired, inactive }
enum WheelActionEffect: Equatable { case tap(Int), hold(Int), release }

struct WheelFocusSnapshot {
    let pid: pid_t
    let isAuxiliary: Bool
    let keyboardPID: pid_t?
    init(pid: pid_t, isAuxiliary: Bool = false, keyboardPID: pid_t? = nil) {
        self.pid = pid; self.isAuxiliary = isAuxiliary; self.keyboardPID = keyboardPID
    }
}
enum WheelActionDestination { case target, transient, other }
enum WheelFocusPolicy {
    static func destination(targetPID: pid_t?, frontmost: WheelFocusSnapshot?) -> WheelActionDestination {
        guard let targetPID else { return .other }
        guard let frontmost else { return .transient }
        if frontmost.keyboardPID == targetPID { return .target }
        // A different regular application is a target switch. Auxiliary UI can
        // temporarily activate while the original app remains the input target.
        if !frontmost.isAuxiliary && frontmost.pid != targetPID { return .other }
        if let keyboardPID = frontmost.keyboardPID {
            return keyboardPID == targetPID ? .target : .transient
        }
        return frontmost.pid == targetPID ? .target : .transient
    }
}

// Selection and execution stay separate. In particular, cancellation never
// executes a queued release action, and a previous sector cannot remain held.
struct WheelActivation {
    private(set) var candidate: Int?
    private(set) var committed: Int?
    private(set) var phase: WheelFeedback = .idle
    private var holding = false
    mutating func move(to next: Int?) -> [WheelActionEffect] {
        guard next != candidate else { return [] }
        let effects: [WheelActionEffect] = holding ? [.release] : []
        holding = false; candidate = next; committed = nil
        phase = next == nil ? .idle : .selecting
        return effects
    }
    mutating func commit(modes: [TriggerMode], enabled: [Bool]) -> [WheelActionEffect] {
        guard let index = candidate, committed != index,
              modes.indices.contains(index), enabled.indices.contains(index) else { return [] }
        committed = index
        guard enabled[index] else { phase = .inactive; return [] }
        switch modes[index] {
        case .onEntry: phase = .fired; return [.tap(index)]
        case .onRelease: phase = .releaseReady; return []
        case .whileInside: phase = .holding; holding = true; return [.hold(index)]
        }
    }
    mutating func finish(cancel: Bool, modes: [TriggerMode], enabled: [Bool]) -> [WheelActionEffect] {
        var effects: [WheelActionEffect] = holding ? [.release] : []
        // Confirm an uncommitted final selection defensively. Already fired or
        // held selections must not be sent again; center and cancel never tap.
        if !cancel, let index = candidate,
           modes.indices.contains(index), enabled.indices.contains(index), enabled[index],
           committed != index || phase == .releaseReady {
            effects.append(.tap(index))
        }
        self = WheelActivation()
        return effects
    }
}

// Legacy text bindings stay unchanged unless automatic Return is enabled.
struct QuickTextBinding {
    let text: String
    var sendReturn = false
    var storedValue: String { (sendReturn ? "text-enter:" : "text:") + text }
    static func decode(_ value: String) -> Self? {
        if value.hasPrefix("text-enter:") { return Self(text: String(value.dropFirst(11)), sendReturn: true) }
        if value.hasPrefix("text:") { return Self(text: String(value.dropFirst(5))) }
        return nil
    }
}

struct KeyAction: Identifiable {
    let id: String
    let label: String
    let glyph: String
    let key: CGKeyCode
    var flags: CGEventFlags = []
    var held = false
    var text: String?
    var sendReturn = false
    var enabled = true
    var systemShortcut = false
    var operation: AppOperation?
    var systemShortcutReference: SystemShortcut?
    var canHold: Bool { enabled && text == nil && operation == nil && systemShortcutReference == nil }
    // The menu is intentionally small; legacy actions remain resolvable for saved wheels.
    static var presets: [KeyAction] { [find("spotlight"), find("return"), find("screenshot")] }
    static var suggestions: [KeyAction] { presets + [find("settings")] }
    static let all: [KeyAction] = [
        .init(id: "clearText", label: "清空文本框", glyph: "xmark.circle", key: 0, operation: .clearText),
        .init(id: "virtualKeyboard", label: "打开虚拟键盘", glyph: "keyboard", key: 0, operation: .virtualKeyboard),
        .init(id: "settings", label: "打开轮盘设置", glyph: "⚙", key: 0, operation: .settings),
        .init(id: "spotlight", label: "Command＋空格", glyph: "⌘空格", key: 49, flags: .maskCommand, systemShortcut: true),
        .init(id: "screenshot", label: "截图", glyph: "⇧⌘5", key: 23, flags: [.maskCommand, .maskShift], systemShortcut: true),
        .init(id: "option", label: "右 Option", glyph: "⌥", key: 61, flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40), held: true),
        .init(id: "return", label: "回车", glyph: "↵", key: 36),
        .init(id: "delete", label: "退格", glyph: "⌫", key: 51),
        .init(id: "escape", label: "Esc", glyph: "esc", key: 53),
        .init(id: "copy", label: "复制", glyph: "⌘C", key: 8, flags: .maskCommand),
        .init(id: "paste", label: "粘贴", glyph: "⌘V", key: 9, flags: .maskCommand),
        .init(id: "undo", label: "撤销", glyph: "⌘Z", key: 6, flags: .maskCommand),
        .init(id: "tab", label: "Tab", glyph: "⇥", key: 48),
        .init(id: "up", label: "向上", glyph: "↑", key: 126),
        .init(id: "down", label: "向下", glyph: "↓", key: 125),
        .init(id: "left", label: "向左", glyph: "←", key: 123),
        .init(id: "right", label: "向右", glyph: "→", key: 124),
        .init(id: "space", label: "空格", glyph: "␣", key: 49),
        .init(id: "selectAll", label: "全选", glyph: "⌘A", key: 0, flags: .maskCommand),
        .init(id: "redo", label: "重做", glyph: "⇧⌘Z", key: 6, flags: [.maskCommand, .maskShift]),
        .init(id: "command", label: "右 Command", glyph: "⌘", key: 54, flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10), held: true),
        .init(id: "control", label: "右 Control", glyph: "⌃", key: 62, flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000), held: true),
        .init(id: "shift", label: "右 Shift", glyph: "⇧", key: 60, flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x04), held: true)
    ]
    static let empty = KeyAction(id: "empty", label: "未设置", glyph: "＋", key: 0, enabled: false)
    func displayLabel(_ language: AppLanguage) -> String {
        if text != nil || systemShortcutReference != nil { return label }
        return language.keyLabel(language.text(label))
    }
    static func find(_ value: String) -> KeyAction {
        if let recorded = RecordedKey.decode(value) {
            let flags = CGEventFlags(rawValue: recorded.flags)
            let shortcutFlags = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
            let systemShortcut = (recorded.key == 49 && shortcutFlags == .maskCommand) || (recorded.key == 23 && shortcutFlags == [.maskCommand, .maskShift])
            return KeyAction(id: value, label: recorded.label, glyph: recorded.label, key: recorded.key, flags: flags, held: recorded.modifier, systemShortcut: systemShortcut)
        }
        if let shortcut = SystemShortcut.decode(value) {
            return KeyAction(id: value, label: shortcut.name, glyph: "square.stack.3d.up", key: 0, systemShortcutReference: shortcut)
        }
        if let binding = QuickTextBinding.decode(value) {
            return binding.text.isEmpty ? empty : KeyAction(id: value, label: binding.text, glyph: "文字", key: 0, text: binding.text, sendReturn: binding.sendReturn)
        }
        return all.first { $0.id == value } ?? shortcut(value) ?? empty
    }
    static func shortcut(_ input: String) -> KeyAction? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let preset = all.first(where: { $0.label.lowercased() == trimmed.lowercased() || $0.id.lowercased() == trimmed.lowercased() || $0.glyph.lowercased() == trimmed.lowercased() }) { return preset }
        var value = trimmed.lowercased().filter { !$0.isWhitespace }
        for (symbol, name) in [("⌘", "command+"), ("⌥", "option+"), ("⌃", "control+"), ("⇧", "shift+")] { value = value.replacingOccurrences(of: symbol, with: name) }
        let heldKeys: [String: (CGKeyCode, UInt64, String)] = [
            "rightoption": (61, CGEventFlags.maskAlternate.rawValue | 0x40, "右 Option"),
            "option_r": (61, CGEventFlags.maskAlternate.rawValue | 0x40, "右 Option"),
            "右option": (61, CGEventFlags.maskAlternate.rawValue | 0x40, "右 Option"),
            "alt_r": (61, CGEventFlags.maskAlternate.rawValue | 0x40, "右 Option"),
            "右command": (54, CGEventFlags.maskCommand.rawValue | 0x10, "右 Command"),
            "rightcommand": (54, CGEventFlags.maskCommand.rawValue | 0x10, "右 Command"),
            "右control": (62, CGEventFlags.maskControl.rawValue | 0x2000, "右 Control"),
            "rightcontrol": (62, CGEventFlags.maskControl.rawValue | 0x2000, "右 Control"),
            "右shift": (60, CGEventFlags.maskShift.rawValue | 0x04, "右 Shift"),
            "rightshift": (60, CGEventFlags.maskShift.rawValue | 0x04, "右 Shift"),
            "leftoption": (58, CGEventFlags.maskAlternate.rawValue | 0x20, "左 Option"),
            "左option": (58, CGEventFlags.maskAlternate.rawValue | 0x20, "左 Option"),
            "alt": (58, CGEventFlags.maskAlternate.rawValue | 0x20, "左 Option"),
            "cmd": (55, CGEventFlags.maskCommand.rawValue | 0x08, "左 Command"),
            "ctrl": (59, CGEventFlags.maskControl.rawValue | 0x01, "左 Control"),
            "leftshift": (56, CGEventFlags.maskShift.rawValue | 0x02, "左 Shift")
        ]
        if let (key, flags, label) = heldKeys[value] {
            return KeyAction(id: "key:\(key)", label: label, glyph: [61:"⌥",58:"⌥",54:"⌘",55:"⌘",62:"⌃",59:"⌃",60:"⇧",56:"⇧"][key] ?? label, key: key, flags: CGEventFlags(rawValue: flags), held: true)
        }
        if value == "+" { value = "plus" }
        else if value.hasSuffix("++") { value = String(value.dropLast(2)) + "+plus" }
        let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var flags: CGEventFlags = [], glyph = ""
        var used = Set<String>()
        for modifier in parts.dropLast() {
            let canonical: String
            switch modifier {
            case "command", "cmd", "super", "meta": canonical = "command"; flags.insert(.maskCommand)
            case "option", "alt": canonical = "option"; flags.insert(.maskAlternate)
            case "control", "ctrl": canonical = "control"; flags.insert(.maskControl)
            case "shift": canonical = "shift"; flags.insert(.maskShift)
            default: return nil
            }
            guard used.insert(canonical).inserted else { return nil }
        }
        if flags.contains(.maskControl) { glyph += "⌃" }
        if flags.contains(.maskAlternate) { glyph += "⌥" }
        if flags.contains(.maskShift) { glyph += "⇧" }
        if flags.contains(.maskCommand) { glyph += "⌘" }
        let keys: [String: CGKeyCode] = [
            "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
            "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
            "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"`":50,
            "return":36,"enter":36,"回车":36,"tab":48,"space":49,"空格":49,"delete":51,"backspace":51,"退格":51,"escape":53,"esc":53,
            "home":115,"end":119,"pageup":116,"pagedown":121,"forwarddelete":117,"del":117,
            "left":123,"←":123,"right":124,"→":124,"down":125,"↓":125,"up":126,"↑":126,
            "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,"f13":105,"f14":107,"f15":113,"f16":106,"f17":64,"f18":79,"f19":80,"f20":90
        ]
        let shifted: [String: CGKeyCode] = ["plus":24,"!":18,"@":19,"#":20,"$":21,"%":23,"^":22,"&":26,"*":28,"(":25,")":29,"_":27,"{":33,"}":30,":":41,"\"":39,"<":43,">":47,"?":44,"~":50,"|":42]
        guard let key = keys[keyName] ?? shifted[keyName] else { return nil }
        if shifted[keyName] != nil { flags.insert(.maskShift); if !used.contains("shift") { glyph = "⇧" + glyph } }
        let display = ["return":"↵", "enter":"↵", "space":"空格", "escape":"Esc", "backspace":"⌫", "delete":"⌫", "left":"←", "right":"→", "up":"↑", "down":"↓"][keyName] ?? keyName.uppercased()
        glyph += display
        let systemShortcut = (key == 49 && flags == .maskCommand) || (key == 23 && flags == [.maskCommand, .maskShift])
        return KeyAction(id: "shortcut:\(value)", label: glyph, glyph: glyph, key: key, flags: flags, systemShortcut: systemShortcut)
    }
}

struct SlotAppearance: Codable, Equatable {
    var name: String?
    var icon: String?
    var showName = true
    var showIcon = true
    var trigger: TriggerMode?
    var hasCustomAppearance: Bool { name != nil || icon != nil || !showName || !showIcon }
    func visibleName(for action: KeyAction, language: AppLanguage = .chinese) -> String { showName ? name ?? action.displayLabel(language) : "" }
    func visibleIcon(for action: KeyAction) -> String { showIcon ? icon ?? action.glyph : "" }
}

// Value snapshots keep an open gesture independent from settings edits.
struct WheelConfiguration: Codable, Equatable {
    var slots: [String]
    var appearances: [SlotAppearance]
    var rotation: Double
    var onRelease: Bool
    var actions: [KeyAction] { slots.map(KeyAction.find) }
    var triggers: [TriggerMode] {
        slots.indices.map { i in
            let action = actions[i]
            let requested = appearances.indices.contains(i) ? appearances[i].trigger : nil
            let mode = requested ?? (action.held ? .whileInside : onRelease ? .onRelease : .onEntry)
            return mode == .whileInside && !action.canHold ? .onEntry : mode
        }
    }
    func sanitized() -> Self {
        var copy = self
        copy.rotation = rotation.isFinite ? normalizedAngle(rotation) : 0
        copy.appearances = Array(appearances.prefix(slots.count))
        copy.appearances += Array(repeating: SlotAppearance(), count: slots.count - copy.appearances.count)
        for i in slots.indices where copy.appearances[i].trigger == .whileInside && !actions[i].canHold {
            copy.appearances[i].trigger = .onEntry
        }
        return copy
    }
}

struct WheelApplication: Codable, Identifiable, Equatable {
    var id: String // bundle identifier
    var name: String
    var path: String
}

struct ApplicationWheel: Codable, Identifiable, Equatable {
    var id: String // stable profile identifier; legacy profiles use the bundle ID
    var name: String
    var path: String
    var wheel: WheelConfiguration
    var applications: [WheelApplication]? = nil
    // Optional fields preserve pre-condition profiles without rewriting their wheels.
    var scenes: [WheelScene]? = nil
    var matchMode: WheelMatchMode? = nil
    var sceneConditions: [WheelScene] { scenes ?? [] }
    var mode: WheelMatchMode { matchMode ?? .all }
    func matchPriority(bundleID: String?, scene: WheelScene?) -> Int? {
        let appMatches = bundleID.map(contains) ?? false
        let sceneMatches = scene.map { sceneConditions.contains($0) } ?? false
        let hasApps = !members.isEmpty, hasScenes = !sceneConditions.isEmpty
        guard hasApps || hasScenes else { return nil }
        if mode == .all {
            guard (!hasApps || appMatches) && (!hasScenes || sceneMatches) else { return nil }
            return hasApps && hasScenes ? 3 : hasScenes ? 2 : 1
        }
        guard appMatches || sceneMatches else { return nil }
        // An either-condition rule is broad even when both happen to match.
        return sceneMatches ? 2 : 1
    }
    func conditionSummary(language: AppLanguage) -> String {
        let apps = members.map(\.name).joined(separator: "、")
        let sceneNames = sceneConditions.map { language.text($0.title) }.joined(separator: "、")
        if apps.isEmpty { return sceneNames }
        if sceneNames.isEmpty { return apps }
        return apps + language.text(mode == .all ? "，且 " : "，或 ") + sceneNames
    }
    var members: [WheelApplication] { applications ?? [WheelApplication(id: id, name: name, path: path)] }
    func contains(_ bundleID: String) -> Bool { members.contains { $0.id == bundleID } }
}

enum WheelMatchMode: String, Codable, CaseIterable {
    case all, any
    var title: String { self == .all ? "同时符合" : "符合任一" }
}

enum WheelScene: String, Codable, CaseIterable, Identifiable {
    case textInput
    var id: String { rawValue }
    var title: String { "文本框聚焦" }
    var icon: String { "character.cursor.ibeam" }
}

struct SceneWheel: Codable, Identifiable, Equatable {
    var id: String
    var wheel: WheelConfiguration
}

enum WheelEditingTarget: Hashable {
    case global, application(String), scene(WheelScene)
}

struct WheelLibrary: Codable {
    var global: WheelConfiguration
    var applications: [ApplicationWheel]
    // Optional for compatibility with libraries saved before scenes existed.
    var scenes: [SceneWheel]? = nil
}

final class Settings: ObservableObject {
    static let minimumHold = GestureCore.minimumHold
    static let maximumHold = 1.2
    private let defaults: UserDefaults
    private var persistenceEnabled = false
    @Published private(set) var selectedTarget: WheelEditingTarget = .global
    var selectedApplicationID: String? {
        if case .application(let id) = selectedTarget { return id }; return nil
    }
    var selectedScene: WheelScene? {
        if case .scene(let scene) = selectedTarget { return scene }; return nil
    }
    @Published private(set) var sceneWheels: [SceneWheel] = []
    @Published private(set) var applicationWheels: [ApplicationWheel] = []
    private var globalWheel: WheelConfiguration!
    var editingWheel: WheelConfiguration {
        WheelConfiguration(slots: slots, appearances: appearances, rotation: rotation, onRelease: onRelease).sanitized()
    }
    func wheel(for bundleIdentifier: String?, scene: WheelScene? = nil) -> WheelConfiguration {
        var result = globalWheel!, priority = 0
        // Preserve legacy scene-before-app routing. More specific combined rules
        // outrank it; equal-priority rules use their persisted list order.
        if let scene, let profile = sceneWheels.first(where: { $0.id == scene.rawValue }) {
            result = profile.wheel; priority = 2
        }
        for profile in applicationWheels {
            if let match = profile.matchPriority(bundleID: bundleIdentifier, scene: scene), match > priority {
                result = profile.wheel; priority = match
            }
        }
        return result
    }
    var needsTextInputScene: Bool {
        sceneWheels.contains { $0.id == WheelScene.textInput.rawValue }
            || applicationWheels.contains { $0.sceneConditions.contains(.textInput) }
    }
    @discardableResult
    func setWheelRule(id: String?, replacingScene: WheelScene? = nil, name: String,
                      applications: [WheelApplication], scenes: [WheelScene], mode: WheelMatchMode) -> Bool {
        guard !applications.isEmpty || !scenes.isEmpty,
              Set(applications.map(\.id)).count == applications.count,
              applications.allSatisfy({ !$0.id.isEmpty && !$0.id.contains(where: { $0.isWhitespace }) }),
              Set(scenes).count == scenes.count,
              id == nil || applicationWheels.contains(where: { $0.id == id }),
              replacingScene == nil || (id == nil && sceneWheels.contains { $0.id == replacingScene?.rawValue }) else { return false }
        save()
        let existing = id.flatMap { target in applicationWheels.first { $0.id == target } }
        let sceneWheel = replacingScene.flatMap { scene in sceneWheels.first { $0.id == scene.rawValue } }
        let ruleID = existing?.id ?? UUID().uuidString
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = ApplicationWheel(id: ruleID, name: title, path: applications.count == 1 ? applications[0].path : "",
            wheel: existing?.wheel ?? sceneWheel?.wheel ?? globalWheel, applications: applications, scenes: scenes, matchMode: mode)
        if title.isEmpty { profile.name = profile.conditionSummary(language: language) }
        KeyRecorderButton.active?.stop()
        persistenceEnabled = false
        if let index = applicationWheels.firstIndex(where: { $0.id == ruleID }) { applicationWheels[index] = profile }
        else { applicationWheels.append(profile) }
        if let replacingScene { sceneWheels.removeAll { $0.id == replacingScene.rawValue } }
        selectedTarget = .application(ruleID); loadWheel(profile.wheel)
        persistenceEnabled = true; save()
        return true
    }
    var profileTargets: [WheelEditingTarget] {
        [.global] + applicationWheels.map { .application($0.id) }
            + WheelScene.allCases.filter { scene in sceneWheels.contains { $0.id == scene.rawValue } }.map { .scene($0) }
    }
    func profileTitle(_ target: WheelEditingTarget) -> String {
        switch target {
        case .global: return l("全局")
        case .application(let id):
            guard let profile = applicationWheels.first(where: { $0.id == id }) else { return "" }
            return profile.name + (applicationWheels.filter { $0.name == profile.name }.count > 1 ? " · " + String(id.prefix(8)) : "")
        case .scene(let scene): return l(scene.title)
        }
    }
    @discardableResult
    func removeProfile(_ target: WheelEditingTarget) -> Bool {
        guard target != .global, profileTargets.contains(target) else { return false }
        // Deleting an unselected scene must keep the editor on its current wheel.
        if target == selectedTarget { selectTarget(.global) }
        else { save() }
        switch target {
        case .application(let id): applicationWheels.removeAll { $0.id == id }
        case .scene(let scene): sceneWheels.removeAll { $0.id == scene.rawValue }
        case .global: return false
        }
        save(); return true
    }
    @discardableResult
    func copyWheel(from source: WheelEditingTarget) -> Bool {
        guard source != selectedTarget, profileTargets.contains(source) else { return false }
        save()
        let wheel: WheelConfiguration
        switch source {
        case .global: wheel = globalWheel
        case .application(let id):
            guard let profile = applicationWheels.first(where: { $0.id == id }) else { return false }
            wheel = profile.wheel
        case .scene(let scene):
            guard let profile = sceneWheels.first(where: { $0.id == scene.rawValue }) else { return false }
            wheel = profile.wheel
        }
        KeyRecorderButton.active?.stop()
        persistenceEnabled = false; loadWheel(wheel)
        persistenceEnabled = true; save()
        return true
    }
    func selectApplication(_ id: String?) {
        selectTarget(id.map(WheelEditingTarget.application) ?? .global)
    }
    func selectTarget(_ target: WheelEditingTarget) {
        guard target != selectedTarget else { return }
        let configuration: WheelConfiguration
        switch target {
        case .global: configuration = globalWheel
        case .application(let id):
            guard let profile = applicationWheels.first(where: { $0.id == id }) else { return }
            configuration = profile.wheel
        case .scene(let scene):
            guard let profile = sceneWheels.first(where: { $0.id == scene.rawValue }) else { return }
            configuration = profile.wheel
        }
        KeyRecorderButton.active?.stop()
        save()
        persistenceEnabled = false
        selectedTarget = target
        loadWheel(configuration)
        persistenceEnabled = true
    }
    func addScene(_ scene: WheelScene) {
        if !sceneWheels.contains(where: { $0.id == scene.rawValue }) {
            sceneWheels.append(SceneWheel(id: scene.rawValue, wheel: globalWheel))
        }
        selectTarget(.scene(scene)); save()
    }
    func removeSelectedScene() {
        guard selectedScene != nil else { return }
        removeProfile(selectedTarget)
    }
    @discardableResult
    func addApplication(id: String, name: String, path: String) -> Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let existing = applicationWheels.first(where: { $0.sceneConditions.isEmpty && $0.contains(id) }) {
            selectApplication(existing.id); return true
        }
        applicationWheels.append(ApplicationWheel(id: id, name: name, path: path, wheel: globalWheel))
        selectApplication(id); save(); return true
    }
    // Compatibility helper for app-only callers; membership is no longer exclusive.
    @discardableResult
    func setApplicationGroup(id: String?, name: String, applications: [WheelApplication]) -> Bool {
        guard !applications.isEmpty else { return false }
        let existing = id.flatMap { target in applicationWheels.first { $0.id == target } }
        return setWheelRule(id: id, name: name, applications: applications,
                           scenes: existing?.sceneConditions ?? [], mode: existing?.mode ?? .all)
    }
    func removeSelectedApplication() {
        guard selectedApplicationID != nil else { return }
        removeProfile(selectedTarget)
    }
    private func loadWheel(_ wheel: WheelConfiguration) {
        let clean = wheel.sanitized()
        slots = clean.slots; appearances = clean.appearances
        rotation = clean.rotation; onRelease = clean.onRelease
    }
    @Published var language: AppLanguage = .chinese { didSet { save() } }
    func l(_ text: String) -> String { language.text(text) }
    @Published var theme: WheelTheme = .minimal { didSet { save() } }
    @Published var enabled: Bool = true { didSet { save() } }
    let fingers = 2
    @Published var rotation: Double = 0 { didSet { save() } }
    @Published var hold: Double = 0.45 { didSet { save() } }
    @Published var travel: Double = 0.14 { didSet { save() } }
    @Published var onRelease: Bool = false { didSet { save() } }
    @Published var slots = ["option", "return", "delete", "escape", "copy", "paste", "undo", "tab"] { didSet { alignAppearances(); save() } }
    @Published var appearances: [SlotAppearance] = [] { didSet { save() } }
    @Published var permission = false
    @Published var deviceCount = 0
    @Published var contacts = 0
    @Published var status = "正在连接触控板…"
    @Published var lastAction = "等待你的手势"
    @Published var hookReady = false
    var actions: [KeyAction] { slots.map(KeyAction.find) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        // Existing installations keep their glass appearance; new users start simple.
        let existing = ["wheelLibrary.v1", "slots", "hold", "slotAppearances"].contains { d.object(forKey: $0) != nil }
        if d.object(forKey: "wheelEnabled") != nil { enabled = d.bool(forKey: "wheelEnabled") }
        language = d.string(forKey: "interfaceLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .chinese
        let savedTheme = d.string(forKey: "wheelTheme")
        theme = savedTheme.flatMap(WheelTheme.restored) ?? (existing ? .glass : .minimal)
        let savedRotation = d.double(forKey: "rotation")
        rotation = savedRotation.isFinite ? normalizedAngle(savedRotation) : 0
        if d.object(forKey: "hold") != nil {
            hold = min(Self.maximumHold, max(Self.minimumHold, d.double(forKey: "hold")))
            travel = min(0.25, max(0.07, d.double(forKey: "travel")))
            onRelease = d.bool(forKey: "onRelease")
            if let values = d.stringArray(forKey: "slots") { slots = values }
        }
        if let data = d.data(forKey: "slotAppearances"), let saved = try? JSONDecoder().decode([SlotAppearance].self, from: data) { appearances = saved }
        alignAppearances()
        globalWheel = editingWheel
        if let data = d.data(forKey: "wheelLibrary.v1"), let saved = try? JSONDecoder().decode(WheelLibrary.self, from: data) {
            globalWheel = saved.global.sanitized()
            var seen = Set<String>()
            applicationWheels = saved.applications.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.map {
                var profile = $0; profile.wheel = profile.wheel.sanitized(); return profile
            }
            seen.removeAll()
            sceneWheels = (saved.scenes ?? []).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.map {
                var profile = $0; profile.wheel = profile.wheel.sanitized(); return profile
            }
            loadWheel(globalWheel)
        }
        persistenceEnabled = true
        save()
    }
    private func alignAppearances() {
        if appearances.count < slots.count { appearances += Array(repeating: SlotAppearance(), count: slots.count - appearances.count) }
        else if appearances.count > slots.count { appearances = Array(appearances.prefix(slots.count)) }
    }
    func appearance(at index: Int) -> SlotAppearance { appearances.indices.contains(index) ? appearances[index] : SlotAppearance() }
    func setAppearance(_ value: SlotAppearance, at index: Int) {
        guard slots.indices.contains(index), appearances.indices.contains(index) else { return }
        if appearances[index] != value { appearances[index] = value }
    }
    func trigger(at index: Int) -> TriggerMode {
        guard actions.indices.contains(index) else { return .onEntry }
        let action = actions[index]
        let requested = appearance(at: index).trigger ?? (action.held ? .whileInside : onRelease ? .onRelease : .onEntry)
        return requested == .whileInside && !action.canHold ? .onEntry : requested
    }
    var triggers: [TriggerMode] { slots.indices.map { trigger(at: $0) } }
    func setTrigger(_ mode: TriggerMode, at index: Int) {
        guard slots.indices.contains(index), mode != .whileInside || actions[index].canHold else { return }
        var style = appearance(at: index); style.trigger = mode
        setAppearance(style, at: index)
    }
    func resetAppearance(at index: Int) {
        var style = SlotAppearance(); style.trigger = appearance(at: index).trigger
        setAppearance(style, at: index)
    }
    func assignShortcut(_ shortcut: SystemShortcut, at index: Int) {
        guard slots.indices.contains(index) else { return }
        let previousMode = trigger(at: index)
        slots[index] = shortcut.storedValue
        if previousMode == .whileInside { setTrigger(.onRelease, at: index) }
    }
    func removeSlot(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        var remaining = appearances; remaining.remove(at: index)
        slots.remove(at: index)
        appearances = remaining
    }
    @discardableResult
    func updateSlot(_ index: Int, input: String, textMode: Bool, sendReturn: Bool? = nil) -> Bool {
        guard slots.indices.contains(index) else { return false }
        let value = textMode ? input : input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard textMode || value.isEmpty || RecordedKey.decode(value) != nil || KeyAction.shortcut(value) != nil else { return false }
        let stored = textMode ? QuickTextBinding(text: value, sendReturn: sendReturn ?? QuickTextBinding.decode(slots[index])?.sendReturn ?? false).storedValue : value
        if slots[index] != stored { slots[index] = stored }
        return true
    }
    // The destination is a gap in the original order, before the given slot.
    // Removing the source shifts later gaps by one; all other slots keep order.
    @discardableResult
    func insertSlot(_ source: Int, before boundary: Int) -> Int? {
        guard slots.indices.contains(source), (0...slots.count).contains(boundary) else { return nil }
        let destination = boundary > source ? boundary - 1 : boundary
        guard destination != source else { return nil }
        var reordered = slots
        let action = reordered.remove(at: source)
        reordered.insert(action, at: destination)
        var styles = appearances
        let style = styles.remove(at: source)
        styles.insert(style, at: destination)
        // Persist only the complete action/appearance pair, never the intermediate order.
        let wasEnabled = persistenceEnabled
        persistenceEnabled = false
        slots = reordered; appearances = styles
        persistenceEnabled = wasEnabled; save()
        return destination
    }
    var library: WheelLibrary {
        WheelLibrary(global: globalWheel, applications: applicationWheels, scenes: sceneWheels)
    }
    func applyImport(_ file: SettingsFile) throws {
        let imported = try file.validatedLibrary()
        KeyRecorderButton.active?.stop()
        persistenceEnabled = false
        language = file.preferences.language; theme = file.preferences.theme
        enabled = file.preferences.enabled; hold = file.preferences.holdSeconds; travel = file.preferences.travel
        globalWheel = imported.global; applicationWheels = imported.applications; sceneWheels = imported.scenes ?? []
        selectedTarget = .global; loadWheel(globalWheel)
        persistenceEnabled = true; save()
    }
    func save() {
        guard persistenceEnabled else { return }
        let snapshot = editingWheel
        if let id = selectedApplicationID, let index = applicationWheels.firstIndex(where: { $0.id == id }) {
            if applicationWheels[index].wheel != snapshot { applicationWheels[index].wheel = snapshot }
        } else if let scene = selectedScene, let index = sceneWheels.firstIndex(where: { $0.id == scene.rawValue }) {
            if sceneWheels[index].wheel != snapshot { sceneWheels[index].wheel = snapshot }
        } else { globalWheel = snapshot }
        let d = defaults
        if let data = try? JSONEncoder().encode(WheelLibrary(global: globalWheel, applications: applicationWheels, scenes: sceneWheels)) { d.set(data, forKey: "wheelLibrary.v1") }
        // Retain the legacy global keys for migration and older app versions.
        d.set(enabled, forKey: "wheelEnabled")
        d.set(language.rawValue, forKey: "interfaceLanguage")
        d.set(theme.rawValue, forKey: "wheelTheme")
        d.set(fingers, forKey: "fingers"); d.set(globalWheel.rotation, forKey: "rotation")
        d.set(hold, forKey: "hold"); d.set(travel, forKey: "travel")
        d.set(globalWheel.onRelease, forKey: "onRelease"); d.set(globalWheel.slots, forKey: "slots")
        if let data = try? JSONEncoder().encode(globalWheel.appearances) { d.set(data, forKey: "slotAppearances") }
    }
}

final class KeySender {
    private var held: KeyAction?
    private let source = CGEventSource(stateID: .privateState)
    private let isTrusted: () -> Bool
    private let emit: (CGEvent, CGEventTapLocation) -> Void
    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         emit: @escaping (CGEvent, CGEventTapLocation) -> Void = { $0.post(tap: $1) }) {
        self.isTrusted = isTrusted; self.emit = emit
    }
    // Distinct tag so our synthetic events can never cancel their own gesture.
    static let eventTag: Int64 = 0x4D574845454C
    var available: Bool { isTrusted() }
    static func traceEvent(_ event: CGEvent, stage: String) {
        guard CommandLine.arguments.contains("--trace-actions") else { return }
        fputs("Orvia delivery: t=\(ProcessInfo.processInfo.systemUptime) stage=\(stage) type=\(event.type.rawValue) key=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=\(event.flags.rawValue) globalFlags=\(CGEventSource.flagsState(.combinedSessionState).rawValue) timestamp=\(event.timestamp) source=\(event.getIntegerValueField(.eventSourceUnixProcessID)) recipient=\(event.getIntegerValueField(.eventTargetUnixProcessID))\n", stderr)
    }
    private func post(_ action: KeyAction, down: Bool, location: CGEventTapLocation = .cghidEventTap) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: action.key, keyDown: down) else { return }
        event.flags = down || !action.held ? action.flags : []
        // Function-row key events need this intrinsic bit for macOS global
        // hotkey matching, even when no separate Fn key was configured.
        if !action.held && RecordedKey.functionKeyCodes.contains(action.key) {
            event.flags.insert(.maskSecondaryFn)
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        if action.held { event.type = .flagsChanged }
        // Any user-defined key can be a third-party global shortcut. Send each
        // physical key pair through HID once so early listeners receive it too.
        // Unicode text deliberately keeps its separate session delivery below.
        Self.traceEvent(event, stage: location == .cghidEventTap ? "posted HID" : "posted session")
        emit(event, location)
    }
    func tap(_ action: KeyAction) {
        guard available else { return }
        guard action.enabled, action.operation == nil, action.systemShortcutReference == nil else { return }
        release()
        if let text = action.text {
            // Keep UTF-16 surrogate pairs intact when emitting long text.
            var buffer: [UniChar] = []
            func flush() {
                guard !buffer.isEmpty else { return }
                for down in [true, false] {
                    if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) {
                        event.flags = []
                        buffer.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: $0.baseAddress) }
                        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
                        Self.traceEvent(event, stage: "posted session")
                        emit(event, .cgSessionEventTap)
                    }
                }
                buffer.removeAll(keepingCapacity: true)
            }
            for scalar in text.unicodeScalars {
                let units = Array(String(scalar).utf16)
                if buffer.count + units.count > 20 { flush() }
                buffer.append(contentsOf: units)
            }
            flush()
            if action.sendReturn && !text.isEmpty {
                // Use the same injection point as the text to retain ordering.
                let enter = KeyAction.find("return")
                post(enter, down: true, location: .cgSessionEventTap)
                post(enter, down: false, location: .cgSessionEventTap)
            }
        } else { post(action, down: true); post(action, down: false) }
    }
    func hold(_ action: KeyAction) {
        guard available else { return }
        guard action.canHold else { return }
        if held?.id == action.id { return }
        release(); held = action; post(action, down: true)
    }
    func release() {
        if let action = held { post(action, down: false); held = nil }
    }
}
