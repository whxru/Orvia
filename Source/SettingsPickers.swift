import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SceneProfilePicker: View {
    @ObservedObject var model: Settings
    let requestDeletion: (WheelEditingTarget) -> Void
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Text(model.profileTitle(model.selectedTarget)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(maxWidth: 180)
        }.accessibilityLabel(model.l("轮盘配置"))
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.profileTargets, id: \.self) { target in
                        HStack(spacing: 8) {
                            Button {
                                model.selectTarget(target); expanded = false
                            } label: {
                                HStack {
                                    Image(systemName: model.selectedTarget == target ? "checkmark" : "circle")
                                        .opacity(model.selectedTarget == target ? 1 : 0).frame(width: 14)
                                    Text(model.profileTitle(target)).lineLimit(2)
                                    Spacer()
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if target != .global {
                                Button {
                                    expanded = false; requestDeletion(target)
                                } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                                    .buttonStyle(.borderless)
                                    .help(model.l("删除场景"))
                                    .accessibilityLabel(model.l("删除场景") + " · " + model.profileTitle(target))
                            }
                        }.background(model.selectedTarget == target ? Color.primary.opacity(0.06) : .clear)
                            .cornerRadius(6)
                    }
                }.padding(8)
            }.frame(width: 280, height: min(320, CGFloat(model.profileTargets.count) * 44 + 16))
        }
    }
}

struct WheelCopyPanel: View {
    @ObservedObject var model: Settings
    let didCopy: () -> Void
    let dismiss: () -> Void
    @State private var source: WheelEditingTarget = .global
    var sources: [WheelEditingTarget] { model.profileTargets.filter { $0 != model.selectedTarget } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.l("从其他场景导入轮盘")).font(.title3.weight(.semibold))
            Text(model.l("选择来源场景")).font(.callout)
            Picker(model.l("来源场景"), selection: $source) {
                ForEach(sources, id: \.self) { Text(model.profileTitle($0)).tag($0) }
            }.labelsHidden().frame(maxWidth: .infinity)
            Text(model.l("导入会替换当前轮盘的键位和外观，保留当前场景的名称及应用范围。之后可独立修改，来源场景不受影响。"))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.l("取消"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(model.l("导入轮盘")) {
                    if model.copyWheel(from: source) { didCopy(); dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(!sources.contains(source))
            }
        }.padding(22).frame(width: 440)
        .onAppear { source = sources.first ?? .global }
    }
}

struct WheelConditionsPanel: View {
    @ObservedObject var model: Settings
    private func l(_ text: String) -> String { model.l(text) }
    let focused: NSRunningApplication?
    var editingGroupID: String? = nil
    var editingScene: WheelScene? = nil
    let dismiss: () -> Void
    @State private var search = ""
    @State private var name = ""
    @State private var error = ""
    @State private var applications: [WheelApplication] = []
    @State private var selectedIDs = Set<String>()
    @State private var requiresTextFocus = false
    private var selectedApps: [WheelApplication] { applications.filter { selectedIDs.contains($0.id) } }
    private var scenes: [WheelScene] { requiresTextFocus ? [.textInput] : [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l(editingGroupID == nil && editingScene == nil ? "添加场景" : "编辑场景"))
                .font(.title3.weight(.semibold))
            TextField(l("场景名称（可选）"), text: $name).textFieldStyle(.roundedBorder)
            Text(l("应用")).font(.headline)
            Text(l("可选择多个应用；不选时适用于所有应用。"))
                .font(.caption).foregroundColor(.secondary)
            if let focused, let id = focused.bundleIdentifier, applications.contains(where: { $0.id == id }) {
                Toggle(l("刚才聚焦：") + (focused.localizedName ?? id), isOn: selection(id))
            }
            TextField(l("搜索应用"), text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { app in
                        Toggle(isOn: selection(app.id)) {
                            HStack(spacing: 10) {
                                Image(nsImage: appIcon(app)).resizable().frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name)
                                    Text(app.id).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }.padding(6)
                    }
                }
            }.frame(height: 230)
            HStack {
                Button(l("选择其他应用…"), action: browse)
                Spacer()
                if !selectedIDs.isEmpty { Button(l("清除选择")) { selectedIDs.removeAll() } }
            }
            Divider()
            Toggle(l("仅在文本框聚焦时"), isOn: $requiresTextFocus)
            Text(l("勾选后，仅在上述应用的文本框中使用。"))
                .font(.caption).foregroundColor(.secondary)
            if !error.isEmpty { Text(error).font(.callout).foregroundColor(.secondary) }
            HStack {
                Spacer()
                Button(l("取消"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(l("保存"), action: save).keyboardShortcut(.defaultAction)
                    .disabled(selectedIDs.isEmpty && !requiresTextFocus)
            }
        }.padding(22).frame(width: 500)
        .onAppear {
            var items = model.applicationWheels.flatMap(\.members)
            items += NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.compactMap {
                guard let id = $0.bundleIdentifier else { return nil }
                return WheelApplication(id: id, name: $0.localizedName ?? id, path: $0.bundleURL?.path ?? "")
            }
            var seen = Set<String>()
            applications = items.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if let group = model.applicationWheels.first(where: { $0.id == editingGroupID }) {
                name = group.name; selectedIDs = Set(group.members.map(\.id))
                requiresTextFocus = group.sceneConditions.contains(.textInput)
            } else if let editingScene {
                name = l(editingScene.title); requiresTextFocus = true
            }
        }
    }
    private func selection(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedIDs.contains(id) }, set: { if $0 { selectedIDs.insert(id) } else { selectedIDs.remove(id) } })
    }
    private func appIcon(_ app: WheelApplication) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) { return NSWorkspace.shared.icon(forFile: url.path) }
        if !app.path.isEmpty { return NSWorkspace.shared.icon(forFile: app.path) }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
    private func save() {
        if model.setWheelRule(id: editingGroupID, replacingScene: editingScene, name: name,
                             applications: selectedApps, scenes: scenes, mode: .all) { dismiss() }
    }
    private func browse() {
        let panel = NSOpenPanel()
        panel.title = l("选择应用"); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        error = ""
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else {
                error = l("所选应用没有 Bundle ID，无法建立配置。"); continue
            }
            let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            if !applications.contains(where: { $0.id == id }) { applications.append(WheelApplication(id: id, name: appName, path: url.path)) }
            selectedIDs.insert(id)
        }
    }
}

struct KeyboardKey: Identifiable {
    let code: UInt16
    var width: CGFloat = 1
    var id: UInt16 { code }
    init(_ code: UInt16, _ width: CGFloat = 1) { self.code = code; self.width = width }
    var title: String {
        [36:"return ↵",48:"tab ⇥",49:"空格",51:"delete ⌫",53:"esc",54:"⌘\n右 command",55:"⌘\n左 command",56:"⇧ 左 shift",57:"caps lock ⇪",58:"⌥\n左 option",59:"⌃\n左 control",60:"右 shift ⇧",61:"⌥\n右 option",62:"⌃\n右 control",63:"fn",65:".",76:"enter",114:"Help"][code] ?? RecordedKey.capture(key: code, flags: []).label
    }
}

enum KeyboardLayout {
    static var rows: [[KeyboardKey]] { [
        [KeyboardKey(53,1.5)] + [122,120,99,118,96,97,98,100,101,109,103,111].map { KeyboardKey(UInt16($0)) },
        [50,18,19,20,21,23,22,26,28,25,29,27,24].map { KeyboardKey(UInt16($0)) } + [KeyboardKey(51,1.6)],
        [KeyboardKey(48,1.5)] + [12,13,14,15,17,16,32,34,31,35,33,30].map { KeyboardKey(UInt16($0)) } + [KeyboardKey(42,1.1)],
        [KeyboardKey(57,1.8)] + [0,1,2,3,5,4,38,40,37,41,39].map { KeyboardKey(UInt16($0)) } + [KeyboardKey(36,1.8)],
        [KeyboardKey(56,2.3)] + [6,7,8,9,11,45,46,43,47,44].map { KeyboardKey(UInt16($0)) } + [KeyboardKey(60,2.3)],
        [KeyboardKey(63),KeyboardKey(59,1.2),KeyboardKey(58,1.2),KeyboardKey(55,1.35),KeyboardKey(49,4.6),KeyboardKey(54,1.35),KeyboardKey(61,1.2),KeyboardKey(62,1.2)]
    ] }
}

struct ManualKeyPicker: View {
    let language: AppLanguage
    private func l(_ text: String) -> String { language.text(text) }
    let dismiss: () -> Void
    let save: (String) -> Void
    @State private var selection: VirtualKeyboardSelection
    @State private var extended = false
    init(initial: KeyAction, language: AppLanguage = .chinese, dismiss: @escaping () -> Void, save: @escaping (String) -> Void) {
        self.language = language; self.dismiss = dismiss; self.save = save
        _selection = State(initialValue: VirtualKeyboardSelection(action: initial))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l("手动配置按键")).font(.title2.weight(.semibold))
                    Text(l("点击按键选择；修饰键可叠加，再点一次取消。左右键独立选择。"))
                        .font(.callout).foregroundColor(.secondary)
                }
                Spacer()
                Button(l("清除选择")) { selection.clear() }.disabled(selection.recorded == nil)
            }
            Picker(l("键盘区域"), selection: $extended) {
                Text(l("主键盘")).tag(false)
                Text(l("数字键盘与扩展")).tag(true)
            }.pickerStyle(.segmented).frame(width: 300)
            VStack(spacing: 6) {
                if extended {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(spacing: 6) {
                            keyRow([71,81,75,67].map { KeyboardKey(UInt16($0)) })
                            keyRow([89,91,92,78].map { KeyboardKey(UInt16($0)) })
                            keyRow([86,87,88,69].map { KeyboardKey(UInt16($0)) })
                            keyRow([83,84,85,76].map { KeyboardKey(UInt16($0)) })
                            keyRow([KeyboardKey(82,2),KeyboardKey(65),KeyboardKey(49)])
                        }.frame(width: 280)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(l("导航与功能键")).font(.callout).foregroundColor(.secondary)
                            keyRow([114,115,116,117,119,121].map { KeyboardKey(UInt16($0)) })
                            keyRow([105,107,113,106].map { KeyboardKey(UInt16($0)) })
                            keyRow([64,79,80,90].map { KeyboardKey(UInt16($0)) })
                            keyRow([59,58,56,55,63].map { KeyboardKey(UInt16($0)) })
                        }
                    }
                } else {
                    ForEach(KeyboardLayout.rows.indices, id: \.self) { index in keyRow(KeyboardLayout.rows[index], height: index == 0 ? 32 : 43) }
                }
                HStack {
                    Text(l("灰色按键为当前选择")).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    keyRow([123,125,126,124].map { KeyboardKey(UInt16($0)) }, height: 30).frame(width: 200)
                }.padding(.top, 4)
            }.padding(12)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l("当前按键")).font(.caption).foregroundColor(.secondary)
                    Text(selection.recorded.map { language.keyLabel($0.label) } ?? l("请选择按键")).font(.title3.weight(.medium)).lineLimit(1)
                        .accessibilityLabel(l("配置结果：") + (selection.recorded.map { language.keyLabel($0.label) } ?? l("未选择")))
                }
                Spacer()
                Button(l("取消"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(l("保存按键")) { if let value = selection.recorded { save(value.storedValue) } }
                    .keyboardShortcut(.defaultAction).disabled(selection.recorded == nil)
            }
        }.padding(24).frame(width: 800).tint(.primary)
    }
    private func keyRow(_ keys: [KeyboardKey], height: CGFloat = 43) -> some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width - CGFloat(keys.count - 1) * 5) / keys.reduce(0) { $0 + $1.width }
            HStack(spacing: 5) {
                ForEach(keys) { key in
                    let chosen = selection.contains(key.code)
                    Button { selection.select(key.code) } label: {
                        Text(language.keyLabel(key.title)).font(.system(size: 11, weight: chosen ? .semibold : .regular))
                            .multilineTextAlignment(.center).lineLimit(2)
                            .frame(width: max(0, unit * key.width), height: height)
                            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.primary.opacity(0.20) : Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(chosen ? 0.5 : 0.14), lineWidth: chosen ? 1.5 : 0.7))
                            .shadow(color: .black.opacity(chosen ? 0 : 0.09), radius: 0, y: 2)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(language.keyLabel(RecordedKey.capture(key: key.code, flags: []).label))
                        .accessibilityValue(chosen ? l("已选中") : l("未选中"))
                        .help(language.keyLabel(RecordedKey.capture(key: key.code, flags: []).label))
                }
            }
        }.frame(height: height)
    }
}

// Native menu tracking reports both mouse hover and keyboard highlighting.
// Only selection changes the saved theme; closing the menu clears the preview.
struct ThemeMenu: NSViewRepresentable {
    @Binding var selection: WheelTheme
    @Binding var preview: WheelTheme?
    let language: AppLanguage
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator; button.action = #selector(Coordinator.choose(_:))
        button.menu?.delegate = context.coordinator
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = WheelTheme.allCases.map { language.text($0.title) }
        if button.itemTitles != titles {
            button.removeAllItems(); button.addItems(withTitles: titles)
            for (index, theme) in WheelTheme.allCases.enumerated() { button.item(at: index)?.representedObject = theme.rawValue }
        }
        button.selectItem(at: WheelTheme.allCases.firstIndex(of: selection) ?? 0)
        button.setAccessibilityLabel(language.text("轮盘主题"))
        button.toolTip = language.text("悬停预览，点击应用主题")
    }
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: ThemeMenu
        init(_ parent: ThemeMenu) { self.parent = parent }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            parent.preview = (item?.representedObject as? String).flatMap(WheelTheme.init(rawValue:))
        }
        func menuDidClose(_ menu: NSMenu) { parent.preview = nil }
        @objc func choose(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String, let theme = WheelTheme(rawValue: raw) else { return }
            parent.selection = theme; parent.preview = nil
        }
    }
}
