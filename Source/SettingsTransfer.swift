import AppKit

// Public interchange format; deliberately independent of UserDefaults and paths.
// See docs/settings-format.schema.json and docs/settings-format.zh-CN.md.
struct SettingsFile: Codable {
    static let formatID = "magic-wheel-settings"
    static let currentVersion = 3
    static let maximumBytes = 16 * 1024 * 1024
    var format = Self.formatID
    var version = Self.currentVersion
    var preferences: Preferences
    var global: PortableWheel
    var applicationGroups: [Group]
    var scenes: [Scene]

    struct Preferences: Codable {
        var language: AppLanguage
        var theme: WheelTheme
        var enabled: Bool
        var holdSeconds: Double
        var travel: Double
        var launchAtLogin: Bool
    }
    struct Application: Codable {
        var bundleIdentifier: String
        var name: String
    }
    struct Group: Codable {
        var id: String
        var name: String
        var applications: [Application]
        var wheel: PortableWheel
        var scenes: [WheelScene]? = nil
        var matchMode: WheelMatchMode? = nil
    }
    struct Scene: Codable {
        var id: String
        var wheel: PortableWheel
    }
    struct PortableWheel: Codable {
        var rotation: Double
        var onRelease: Bool
        var slots: [Slot]
        init(_ wheel: WheelConfiguration) {
            let clean = wheel.sanitized()
            rotation = clean.rotation; onRelease = clean.onRelease
            slots = clean.slots.enumerated().map { Slot(action: Action($0.element), appearance: clean.appearances[$0.offset]) }
        }
        func configuration(version: Int) throws -> WheelConfiguration {
            guard rotation.isFinite, (0..<(2 * Double.pi)).contains(rotation) else { throw FileError.invalid }
            guard version >= 3 || slots.allSatisfy({ $0.action.sendReturn == nil }) else { throw FileError.invalid }
            let values = try slots.map { try $0.action.storedValue() }
            let wheel = WheelConfiguration(slots: values, appearances: slots.map(\.appearance), rotation: rotation, onRelease: onRelease)
            for (index, slot) in slots.enumerated() where slot.appearance.trigger == .whileInside {
                guard wheel.actions[index].canHold else { throw FileError.invalid }
            }
            return wheel.sanitized()
        }
    }
    struct Slot: Codable {
        var action: Action
        var appearance: SlotAppearance
    }
    struct Action: Codable {
        enum Kind: String, Codable { case binding, key, text, shortcut }
        var type: Kind
        var value: String?
        var key: RecordedKey?
        var shortcut: SystemShortcut?
        var sendReturn: Bool?
        init(_ stored: String) {
            if let recorded = RecordedKey.decode(stored) { type = .key; key = recorded }
            else if let workflow = SystemShortcut.decode(stored) { type = .shortcut; shortcut = workflow }
            else if let text = QuickTextBinding.decode(stored) {
                type = .text; value = text.text; sendReturn = text.sendReturn ? true : nil
            }
            else { type = .binding; value = stored }
        }
        func storedValue() throws -> String {
            switch type {
            case .binding:
                guard let value, key == nil, shortcut == nil, sendReturn == nil,
                      !["recorded:", "text:", "text-enter:", "mac-shortcut:"].contains(where: value.hasPrefix) else { throw FileError.invalid }
                // Includes empty and legacy free-form bindings. Unknown bindings
                // remain disabled, as they do in locally saved configurations.
                return value
            case .text:
                guard let value, key == nil, shortcut == nil else { throw FileError.invalid }
                return QuickTextBinding(text: value, sendReturn: sendReturn ?? false).storedValue
            case .key:
                guard let key, value == nil, shortcut == nil, sendReturn == nil, key.key < 128, !key.label.isEmpty,
                      key.modifier == (RecordedKey.modifierInfo[key.key] != nil) else { throw FileError.invalid }
                return key.storedValue
            case .shortcut:
                guard let shortcut, value == nil, key == nil, sendReturn == nil,
                      let valid = SystemShortcut(identifier: shortcut.identifier, name: shortcut.name) else { throw FileError.invalid }
                return valid.storedValue
            }
        }
    }
    enum FileError: Error {
        case wrongFormat, unsupportedVersion, tooLarge, invalid
        var message: String {
            switch self {
            case .wrongFormat: return "这不是 Orvia 设置文件。"
            case .unsupportedVersion: return "此设置文件的版本暂不支持，请更新 Orvia 后重试。"
            case .tooLarge: return "设置文件过大（最多 16 MB）。"
            case .invalid: return "设置文件不完整或包含无效配置，当前设置未更改。"
            }
        }
    }
    init(settings: Settings, launchAtLogin: Bool) {
        let library = settings.library
        preferences = Preferences(language: settings.language, theme: settings.theme, enabled: settings.enabled,
                                  holdSeconds: settings.hold, travel: settings.travel, launchAtLogin: launchAtLogin)
        global = PortableWheel(library.global)
        applicationGroups = library.applications.map { group in
            Group(id: group.id, name: group.name,
                  applications: group.members.map { Application(bundleIdentifier: $0.id, name: $0.name) },
                  wheel: PortableWheel(group.wheel), scenes: group.scenes, matchMode: group.matchMode)
        }
        scenes = (library.scenes ?? []).map { Scene(id: $0.id, wheel: PortableWheel($0.wheel)) }
    }
    func validatedLibrary() throws -> WheelLibrary {
        guard format == Self.formatID else { throw FileError.wrongFormat }
        guard (1...Self.currentVersion).contains(version) else { throw FileError.unsupportedVersion }
        guard preferences.holdSeconds.isFinite, (Settings.minimumHold...Settings.maximumHold).contains(preferences.holdSeconds),
              preferences.travel.isFinite, (0.07...0.25).contains(preferences.travel) else { throw FileError.invalid }
        var groupIDs = Set<String>(), appIDs = Set<String>(), sceneIDs = Set<String>()
        let groups = try applicationGroups.map { group -> ApplicationWheel in
            guard !group.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  groupIDs.insert(group.id).inserted,
                  !group.applications.isEmpty || !(group.scenes ?? []).isEmpty,
                  Set(group.scenes ?? []).count == (group.scenes ?? []).count,
                  version >= 2 || ((group.scenes ?? []).isEmpty && group.matchMode == nil) else { throw FileError.invalid }
            var memberIDs = Set<String>()
            let members = try group.applications.map { app -> WheelApplication in
                guard !app.bundleIdentifier.isEmpty, !app.bundleIdentifier.contains(where: { $0.isWhitespace }),
                      !app.name.isEmpty, memberIDs.insert(app.bundleIdentifier).inserted,
                      version >= 2 || appIDs.insert(app.bundleIdentifier).inserted else { throw FileError.invalid }
                return WheelApplication(id: app.bundleIdentifier, name: app.name, path: "")
            }
            return ApplicationWheel(id: group.id, name: group.name, path: "", wheel: try group.wheel.configuration(version: version), applications: members, scenes: group.scenes, matchMode: group.matchMode)
        }
        let sceneProfiles = try scenes.map { scene -> SceneWheel in
            guard WheelScene(rawValue: scene.id) != nil, sceneIDs.insert(scene.id).inserted else { throw FileError.invalid }
            return SceneWheel(id: scene.id, wheel: try scene.wheel.configuration(version: version))
        }
        return WheelLibrary(global: try global.configuration(version: version), applications: groups, scenes: sceneProfiles)
    }
    func encoded() throws -> Data {
        _ = try validatedLibrary()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self); data.append(0x0a)
        guard data.count <= Self.maximumBytes else { throw FileError.tooLarge }
        return data
    }
    static func read(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw FileError.tooLarge }
        // Read the header first so newer versions receive a useful error even
        // when they have a different body shape.
        struct Header: Decodable { var format: String; var version: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.format == formatID else { throw FileError.wrongFormat }
            guard (1...currentVersion).contains(header.version) else { throw FileError.unsupportedVersion }
            let file = try JSONDecoder().decode(Self.self, from: data)
            _ = try file.validatedLibrary()
            return file
        } catch let error as FileError { throw error }
        catch { throw FileError.invalid }
    }
    static func read(from url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw FileError.tooLarge }
        return try read(Data(contentsOf: url))
    }
}
