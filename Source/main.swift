import AppKit
import SwiftUI
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Radial menus stay anchored even at a display edge. AppKit must not clamp them.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct WheelEditor: NSViewRepresentable {
    @ObservedObject var model: Settings
    @Binding var selected: Int?
    var previewTheme: WheelTheme? = nil
    let add: () -> Void
    let insert: (Int, Int) -> Void
    func makeNSView(context: Context) -> WheelSurface {
        let wheel = WheelView(); wheel.editing = true
        let v = WheelSurface(wheel: wheel, frame: NSRect(x: 0, y: 0, width: 440, height: 440))
        v.withinWindow()
        v.wheel.editing = true
        v.wheel.toolTip = "点击扇区编辑，拖到两个扇区之间插入；拖动外圈握柄旋转"
        return v
    }
    func updateNSView(_ view: WheelSurface, context: Context) {
        view.wheel.language = model.language
        view.wheel.actions = model.actions; view.wheel.selected = selected; view.wheel.rotation = model.rotation
        view.wheel.theme = previewTheme ?? model.theme
        view.wheel.appearances = model.appearances
        view.wheel.onSelect = { selected = $0 }
        view.wheel.onAdd = add
        view.wheel.onRotate = { model.rotation = $0 }
        view.wheel.onInsert = insert
        view.wheel.window?.invalidateCursorRects(for: view.wheel)
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let settings: Settings
    let core = GestureCore()
    let sender: KeySender
    lazy var virtualKeyboard = RuntimeKeyboardController(sender: sender)
    let shortcutsClient = ShortcutsClient()
    var runningShortcuts = Set<String>()
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow!
    var panel: WheelPanel!
    var wheel: WheelView!
    var eventTap: CFMachPort?
    var eventSource: CFRunLoopSource?
    private var deliveryTap: CFMachPort?
    private var deliverySource: CFRunLoopSource?
    var heartbeat: Timer?
    var latest: (UInt64, [Contact], Double)?
    var wheelVisible = false
    var demo = false
    var activation = WheelActivation()
    var candidate: Int? { activation.candidate }
    var committed: Int? { activation.committed }
    private(set) var actionsSuspended = false
    var lastExternalApplication: NSRunningApplication?
    var targetPID: pid_t?
    let focusedApplication: (pid_t?) -> WheelFocusSnapshot?
    let deviceIsRunning: (UInt64) -> Bool?
    private var pendingActions: [(action: KeyAction, targetPID: pid_t, expires: Double)] = []
    private var pendingHold: (action: KeyAction, index: Int, targetPID: pid_t, expires: Double)?
    var hasPendingAction: Bool { !pendingActions.isEmpty }
    var targetActions: [KeyAction] = []
    var targetTriggers: [TriggerMode] = []
    private let wheelCursor = WheelCursor()
    var cursorHidden: Bool { wheelCursor.hidden }
    var backgroundCursorEnabled: Bool { wheelCursor.supportsBackgroundHiding }
    var cursorRestoreSucceeded: Bool { wheelCursor.restoreSucceeded }
    var targetRotation = 0.0
    var settingWasEnabled = true
    var watchdog: Timer?
    var configGuardUntil = 0.0
    private var suppressedMouseUps = Set<UInt32>()
    private(set) var monitoringActivity: NSObjectProtocol?
    init(settings: Settings = Settings(), sender: KeySender = KeySender(),
         focusedApplication: @escaping (pid_t?) -> WheelFocusSnapshot? = { targetPID in
             NSWorkspace.shared.frontmostApplication.map {
                 let auxiliary = $0.activationPolicy != .regular
                 return WheelFocusSnapshot(pid: $0.processIdentifier, isAuxiliary: auxiliary,
                                           keyboardPID: auxiliary || $0.processIdentifier != targetPID ? InputActions.keyboardFocusPID() : nil)
             }
         }, deviceIsRunning: @escaping (UInt64) -> Bool? = { device in
             let status = MWDeviceIsRunning(device)
             return status < 0 ? nil : status != 0
         }) {
        self.settings = settings; self.sender = sender; self.focusedApplication = focusedApplication
        self.deviceIsRunning = deviceIsRunning; super.init()
    }
    static func commonTimer(interval: TimeInterval, action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    func updateMonitoringActivity() {
        let needed = settings.enabled && settings.permission && settings.hookReady && settings.deviceCount > 0
        if needed && monitoringActivity == nil {
            monitoringActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Respond to the user's global trackpad gesture")
        } else if !needed { endMonitoringActivity() }
    }
    func endMonitoringActivity() {
        if let activity = monitoringActivity { ProcessInfo.processInfo.endActivity(activity); monitoringActivity = nil }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu(); setupPanel()
        rememberFrontmostApplication()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin { showSettings() }
        startMonitor()
        heartbeat = Self.commonTimer(interval: 1.0 / 60) { [weak self] in self?.tick() }
        watchdog = Self.commonTimer(interval: 1) { [weak self] in
            guard let self else { return }
            let old = self.settings.permission
            self.settings.permission = AXIsProcessTrusted()
            if old && !self.settings.permission { self.suspendActions(reason: "accessibility permission lost") }
            if old != self.settings.permission || (self.settings.permission && self.eventTap == nil) { self.installTap() }
            self.updateMonitoringActivity()
            self.refreshMenu()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockScreen), name: NSWorkspace.screensDidSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockScreen), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        installTap()
        updateMonitoringActivity()
    }
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Bundle.main.url(forResource: "OrviaMenuBar", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "circle.grid.cross", accessibilityDescription: "Orvia")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Orvia"
        statusItem.button?.image = icon
        statusItem.menu = makeStatusMenu()
        refreshMenu()
    }
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func item(_ title: String, _ action: Selector, tag: Int = 0) { let x = NSMenuItem(title: title, action: action, keyEquivalent: ""); x.target = self; x.tag = tag; menu.addItem(x) }
        item("禁用轮盘", #selector(toggleEnabled), tag: 1)
        item("打开设置", #selector(showSettings))
        item("开机启动", #selector(toggleLaunchAtLogin), tag: 2)
        item("退出应用", #selector(quit))
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }
    func refreshMenu() {
        guard let statusItem else { return }
        statusItem.menu?.item(withTag: 1)?.state = settings.enabled ? .off : .on
        let loginStatus = SMAppService.mainApp.status
        statusItem.menu?.item(withTag: 2)?.state = loginStatus == .enabled ? .on : loginStatus == .requiresApproval ? .mixed : .off
        statusItem.menu?.item(withTag: 2)?.toolTip = loginStatus == .requiresApproval ? "等待系统允许；可在系统设置的登录项中开启" : "登录 Mac 后自动运行 Orvia"
        statusItem.button?.appearsDisabled = !settings.enabled
    }
    @objc func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval: try SMAppService.mainApp.unregister()
            default: try SMAppService.mainApp.register()
            }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert(); alert.messageText = "无法更改开机启动"
            alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "好")
            alert.runModal()
        }
        refreshMenu()
    }
    func setupPanel() {
        panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false; panel.canHide = false; panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        wheel = WheelView(frame: panel.contentView!.bounds)
        panel.contentView = WheelSurface(wheel: wheel, frame: wheel.frame)
        wheel.mouseMove = { [weak self] vector in self?.move(vector) }
        wheel.mouseClose = { [weak self] in self?.close(cancel: true) }
    }
    func rememberFrontmostApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), app.activationPolicy == .regular { lastExternalApplication = app }
    }
    @objc func frontmostChanged() {
        rememberFrontmostApplication()
        flushPendingActions()
        if wheelVisible && !demo && !targetIsFrontmost() { suspendActions(reason: "input target changed") }
    }
    @objc func showSettings() {
        rememberFrontmostApplication()
        close(cancel: true); core.reset(); latest = nil
        // Settings participate in ordinary app switching; only the global wheel
        // is an auxiliary overlay. Keep this policy until settings are closed.
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            settingsWindow.title = "Orvia"
            settingsWindow.acceptsMouseMovedEvents = true
            settingsWindow.titlebarAppearsTransparent = true
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.level = .normal
            settingsWindow.collectionBehavior = [.managed, .primary]
            settingsWindow.delegate = self
            settingsWindow.contentView = NSHostingView(rootView: SettingsView(model: settings, controller: self))
            settingsWindow.center()
        }
        settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
    func startMonitor() {
        latest = nil; core.reset()
        let n = MWStart { device, contacts, count in
            let copied = count > 0 && contacts != nil ? (0..<Int(count)).map { i in Contact(id: Int(contacts![i].id), x: contacts![i].x, y: contacts![i].y) } : []
            DispatchQueue.main.async {
                appController?.receive(device: device, contacts: copied)
            }
        }
        settings.deviceCount = max(0, Int(n))
        settings.status = n > 0 ? "已连接 \(n) 个触控设备" : String(cString: MWLastError())
        fputs("Orvia: \(settings.status)\n", stderr)
    }
    func receive(device: UInt64, contacts: [Contact]) {
        // The cached frame belongs to the same device as the gesture. Another
        // trackpad's traffic must not replace its last confirmed contact state.
        guard core.accepts(device: device) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if settings.contacts != contacts.count { settings.contacts = contacts.count }
        latest = (device, contacts, now)
        // Process every frame in order. In particular, an all-fingers-up frame
        // must not be overwritten by a new contact before the next timer tick.
        tick(time: now)
    }
    func tick(time now: Double = ProcessInfo.processInfo.systemUptime) {
        flushPendingActions(time: now)
        if settings.enabled != settingWasEnabled {
            settingWasEnabled = settings.enabled
            close(cancel: true, reason: "monitor enabled state changed"); core.reset(); latest = nil
            updateMonitoringActivity()
        }
        guard settings.enabled else { return }
        if KeyRecorderButton.active != nil { close(cancel: true, reason: "key recording started"); core.reset(); latest = nil; return }
        if wheelVisible && !demo {
            if !settings.permission || !settings.hookReady || !targetIsFrontmost() {
                suspendActions(reason: "input target or listener unavailable")
            }
        }
        if wheelVisible { wheel.animationTime = now; wheelCursor.maintain(time: now) }
        if demo {
            if wheelVisible { commitSelection() }
            return
        }
        guard core.active || (settings.permission && settings.hookReady),
              let (device, contacts, updated) = latest else { return }
        if now - updated > 0.75 {
            if !core.active {
                // Old, unconfirmed contacts cannot open a new wheel.
                close(cancel: true, reason: "stale activation candidate"); core.reset(); latest = nil; return
            }
            if deviceIsRunning(device) == false {
                // A monitor failure cannot prove a lift. Keep the wheel and
                // contact state; stop sending keys until the next gesture.
                suspendActions(reason: "touch device monitor stopped")
            }
        }
        if !core.active {
            core.fingerCount = settings.fingers; core.holdDuration = settings.hold; core.travel = settings.travel
        }
        // Cooldown blocks a new hold, never the release that clears a blocked
        // gesture. Otherwise a quick lift-and-rest leaves the next hold stuck.
        guard contacts.isEmpty || now >= configGuardUntil else { return }
        // Covers a button already held before the first contact callback.
        if !wheelVisible && !core.active && !contacts.isEmpty && ([CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }) { blockPendingForPointerClick() }
        for effect in core.consume(device: device, contacts: contacts, time: now) {
            switch effect {
            case .show: showWheel(demo: false)
            case .move(let vector): move(vector)
            case .finish: close(cancel: false, reason: "finger lift")
            case .cancel: close(cancel: true, reason: "contact gesture canceled")
            }
        }
        if wheelVisible { commitSelection() }
    }
    func showWheel(demo demonstration: Bool) {
        pendingActions.removeAll(); pendingHold = nil
        if wheelVisible { close(cancel: true) }
        let activated = NSWorkspace.shared.frontmostApplication
        let focus = actionFocus()
        let frontmost = focus?.isAuxiliary == true
            ? focus?.keyboardPID.flatMap { NSRunningApplication(processIdentifier: $0) } ?? lastExternalApplication ?? activated
            : activated
        let scene: WheelScene? = !demonstration
            && settings.needsTextInputScene
            && InputActions.isTextInputFocused(in: frontmost) ? .textInput : nil
        let configuration = demonstration ? settings.editingWheel : settings.wheel(for: frontmost?.bundleIdentifier, scene: scene)
        guard !configuration.slots.isEmpty else { return }
        demo = demonstration; wheelVisible = true; actionsSuspended = false; activation = WheelActivation()
        targetPID = focus?.isAuxiliary == true
            ? focus?.keyboardPID ?? frontmost?.processIdentifier
            : focus?.pid ?? frontmost?.processIdentifier
        targetActions = configuration.actions; targetTriggers = configuration.triggers; targetRotation = configuration.rotation
        wheel.language = settings.language
        wheel.theme = settings.theme
        wheel.actions = targetActions; wheel.rotation = targetRotation; wheel.vector = WheelVector(); wheel.selected = nil
        wheel.appearances = configuration.appearances; wheel.triggerModes = targetTriggers
        wheel.feedback = .idle; wheel.animationTime = ProcessInfo.processInfo.systemUptime
        wheel.demonstration = demonstration; panel.ignoresMouseEvents = !demonstration
        let p = NSEvent.mouseLocation
        panel.setFrameOrigin(wheelOrigin(cursor: p, size: panel.frame.size))
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        wheel.beginPresentation()
        _ = wheelCursor.begin()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        settings.lastAction = demonstration ? "预览模式：移动鼠标选择，点击关闭" : "轮盘已打开"
    }
    func move(_ vector: WheelVector) {
        guard wheelVisible else { return }
        wheel.vector = vector
        let next = wheelSector(vector, count: targetActions.count, rotation: targetRotation, previous: candidate)
        if next != candidate {
            let key = next.flatMap { targetActions.indices.contains($0) ? targetActions[$0].key : nil }
            traceAction("selection from=\(candidate ?? -1) to=\(next ?? -1) key=\(key.map(Int.init) ?? -1)")
        }
        apply(activation.move(to: next))
        wheel.selected = candidate
        commitSelection()
    }
    func targetIsFrontmost() -> Bool {
        WheelFocusPolicy.destination(targetPID: targetPID, frontmost: focusedApplication(targetPID)) != .other
    }
    func actionFocus() -> WheelFocusSnapshot? {
        // Passing no liveness hint forces the default provider to query the
        // actual keyboard recipient, even if the original app remains active.
        // Use the cheap hinted snapshot only for ongoing wheel visibility.
        focusedApplication(nil)
    }
    func traceAction(_ message: String) {
        guard CommandLine.arguments.contains("--trace-actions") else { return }
        let focus = focusedApplication(targetPID)
        fputs("Orvia action: t=\(ProcessInfo.processInfo.systemUptime) \(message) target=\(targetPID ?? -1) focus=\(focus?.pid ?? -1) auxiliary=\(focus?.isAuxiliary ?? false) keyboard=\(focus?.keyboardPID ?? -1)\n", stderr)
    }
    func flushPendingActions(time now: Double = ProcessInfo.processInfo.systemUptime) {
        guard !pendingActions.isEmpty || pendingHold != nil else { return }
        guard settings.enabled, settings.permission else {
            pendingActions.removeAll(); pendingHold = nil; return
        }
        let focus = actionFocus()
        let waiting = pendingActions; pendingActions.removeAll()
        for pending in waiting {
            guard now < pending.expires else { traceAction("pending action expired"); continue }
            switch WheelFocusPolicy.destination(targetPID: pending.targetPID, frontmost: focus) {
            case .target:
                executeAction(pending.action)
                traceAction("sent after focus restoration key=\(pending.action.key)")
            case .transient: pendingActions.append(pending)
            case .other: traceAction("pending action canceled: target changed")
            }
        }
        if let pending = pendingHold {
            guard wheelVisible, candidate == pending.index, activation.phase == .holding, now < pending.expires else {
                pendingHold = nil; return
            }
            switch WheelFocusPolicy.destination(targetPID: pending.targetPID, frontmost: focus) {
            case .target: pendingHold = nil; sender.hold(pending.action)
            case .transient: break
            case .other: pendingHold = nil
            }
        }
    }
    func perform(_ action: KeyAction) {
        let focus = actionFocus()
        switch WheelFocusPolicy.destination(targetPID: targetPID, frontmost: focus) {
        case .transient:
            guard let targetPID else { return }
            pendingActions.append((action, targetPID, ProcessInfo.processInfo.systemUptime + 1))
            traceAction("queued during focus transition key=\(action.key) recipient=\(focus?.keyboardPID ?? -1)")
            settings.lastAction = "等待输入焦点恢复：" + action.label
        case .target: executeAction(action)
        case .other: traceAction("action canceled: target changed")
        }
    }
    func executeAction(_ action: KeyAction) {
        if let shortcut = action.systemShortcutReference {
            guard runningShortcuts.insert(shortcut.id).inserted else { return }
            sender.release()
            settings.lastAction = "运行快捷指令：" + shortcut.name
            shortcutsClient.run(shortcut) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.runningShortcuts.remove(shortcut.id)
                    switch result {
                    case .success: self.settings.lastAction = "已完成：" + shortcut.name
                    case .failure(let error):
                        self.settings.lastAction = "快捷指令运行失败：" + shortcut.name
                        let alert = NSAlert(); alert.messageText = "无法运行“\(shortcut.name)”"
                        alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "好")
                        if let window = self.settingsWindow, window.isVisible { alert.beginSheetModal(for: window) }
                        else { alert.runModal() }
                    }
                }
            }
        } else if let operation = action.operation {
            sender.release()
            switch operation {
            case .settings:
                DispatchQueue.main.async { [weak self] in self?.showSettings() }
            case .clearText:
                if !InputActions.clearFocusedText(using: sender) {
                    settings.lastAction = settings.l("当前没有可清空的文本框")
                }
            case .virtualKeyboard:
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.close(cancel: true); self.core.reset(); self.latest = nil
                    self.virtualKeyboard.show(language: self.settings.language)
                }
            }
        } else {
            sender.tap(action)
            traceAction("requested immediate key=\(action.key)")
        }
    }
    func apply(_ effects: [WheelActionEffect]) {
        guard !actionsSuspended else { return }
        for effect in effects {
            switch effect {
            case .release: pendingHold = nil; sender.release()
            case .tap(let index):
                if !demo, targetActions.indices.contains(index) { perform(targetActions[index]) }
            case .hold(let index):
                if !demo, targetActions.indices.contains(index) {
                    switch WheelFocusPolicy.destination(targetPID: targetPID, frontmost: actionFocus()) {
                    case .target: sender.hold(targetActions[index])
                    case .transient:
                        if let targetPID { pendingHold = (targetActions[index], index, targetPID, ProcessInfo.processInfo.systemUptime + 1) }
                    case .other: break
                    }
                }
            }
        }
    }
    func syncFeedback() {
        wheel.feedback = activation.phase
        guard let index = candidate, targetActions.indices.contains(index) else { return }
        let label = targetActions[index].label
        switch activation.phase {
        case .holding: settings.lastAction = "保持按下：" + label
        case .releaseReady: settings.lastAction = "松手执行：" + label
        case .fired: settings.lastAction = "已触发：" + label
        case .inactive: settings.lastAction = "未设置"
        default: return
        }
        if demo { settings.lastAction = "预览 · " + settings.lastAction }
    }
    func commitSelection() {
        guard wheelVisible else { return }
        guard !actionsSuspended else { return }
        guard demo || (targetIsFrontmost() && settings.permission) else {
            suspendActions(reason: "input target or listener unavailable"); return
        }
        apply(activation.commit(modes: targetTriggers, enabled: targetActions.map(\.enabled)))
        syncFeedback()
    }
    func restoreCursor() { wheelCursor.end() }
    func blockPendingForPointerClick() {
        // Click rejection only applies before activation. Pressure changes
        // during an established hold must not dismiss the wheel.
        guard !wheelVisible, !core.active else { return }
        let hasContact = latest.map { !$0.1.isEmpty } ?? core.active
        if hasContact { core.blockUntilLift() }
    }
    // Returns true only for swallowed events. Keep down/up pairs balanced even
    // when the fingers lift and close the wheel before the mouse-up arrives.
    func handlePointerButton(_ type: CGEventType) -> Bool {
        if suppressedMouseUps.remove(type.rawValue) != nil { return true }
        guard !demo else { return false }
        let up: CGEventType
        switch type {
        case .leftMouseDown: up = .leftMouseUp
        case .rightMouseDown: up = .rightMouseUp
        case .otherMouseDown: up = .otherMouseUp
        default: return false
        }
        if wheelVisible {
            suppressedMouseUps.insert(up.rawValue)
            return true
        }
        blockPendingForPointerClick()
        return false
    }
    // Input failures invalidate actions, not the user's physical hold. Once
    // invalidated, this gesture cannot send delayed keys even if focus returns.
    func suspendActions(reason: String) {
        pendingActions.removeAll(); pendingHold = nil
        guard wheelVisible, !demo, !actionsSuspended else { return }
        actionsSuspended = true
        sender.release()
        traceAction("actions suspended reason=\(reason)")
    }
    func close(cancel: Bool, reason: String? = nil) {
        if wheelVisible, let reason { traceAction("close reason=\(reason)") }
        pendingHold = nil
        if cancel { pendingActions.removeAll() }
        let wasVisible = wheelVisible
        let shouldExecute = wasVisible && !cancel && !demo && !actionsSuspended && settings.permission && targetIsFrontmost()
        if let index = candidate, targetActions.indices.contains(index) {
            traceAction("close cancel=\(cancel) execute=\(shouldExecute) phase=\(activation.phase)")
        }
        let effects = activation.finish(cancel: !shouldExecute, modes: targetTriggers, enabled: targetActions.map(\.enabled))
        // Hide the menu and restore the cursor before executing a deferred action.
        sender.release(); panel?.orderOut(nil); restoreCursor(); wheelVisible = false
        demo = false
        apply(effects)
        if wasVisible { configGuardUntil = ProcessInfo.processInfo.systemUptime + 0.25 }
    }
    deinit { restoreCursor(); endMonitoringActivity() }
    func recoverEventTap(after type: CGEventType) {
        // The event tap and touch stream are independent. Recovering a temporary
        // keyboard/mouse listener interruption does not imply a finger lift.
        guard settings.permission else {
            suspendActions(reason: "event tap interrupted without permission"); return
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            settings.hookReady = CGEvent.tapIsEnabled(tap: tap)
        }
        if !settings.hookReady {
            suspendActions(reason: "event tap recovery failed")
        }
        traceAction("event tap interrupted type=\(type.rawValue) recovered=\(settings.hookReady)")
    }
    func installDeliveryTrace() {
        guard CommandLine.arguments.contains("--trace-actions"), settings.permission, deliveryTap == nil else { return }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = appController?.deliveryTap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if event.getIntegerValueField(.eventSourceUserData) == KeySender.eventTag {
                // No AX lookup or reading typed text from this event callback.
                KeySender.traceEvent(event, stage: "annotated")
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            traceAction("annotated delivery trace unavailable"); return
        }
        deliveryTap = tap; deliverySource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        traceAction("annotated delivery trace enabled")
    }
    func installTap() {
        settings.permission = AXIsProcessTrusted()
        installDeliveryTrace()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true); settings.hookReady = true; return }
        guard settings.permission else { return }
        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            guard let c = appController else { return Unmanaged.passUnretained(event) }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                c.recoverEventTap(after: type)
                return Unmanaged.passUnretained(event)
            }
            if let recorder = KeyRecorderButton.active, recorder.consume(type: type, event: event) { return nil }
            if event.getIntegerValueField(.eventSourceUserData) == KeySender.eventTag {
                KeySender.traceEvent(event, stage: "session")
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown || type == .flagsChanged {
                // Physical keyboard input does not end a trackpad hold.
                return Unmanaged.passUnretained(event)
            }
            if c.handlePointerButton(type) { return nil }
            if c.wheelVisible && !c.demo {
                if type == .scrollWheel { return nil }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        if let eventTap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) {
            eventSource = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true); settings.hookReady = true
        } else { settings.hookReady = false; settings.status = "按键监听未启动，请授权后重试" }
    }
    func authorize() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc func reconnect() { close(cancel: true); startMonitor(); installTap(); updateMonitoringActivity() }
    @objc func preview() { latest = nil; core.reset(); showWheel(demo: true) }
    @objc func toggleEnabled() { settings.enabled.toggle(); close(cancel: true); core.reset(); latest = nil; updateMonitoringActivity(); refreshMenu() }
    @objc func willSleep() { close(cancel: true, reason: "system sleep"); core.reset(); latest = nil; endMonitoringActivity(); MWStop() }
    @objc func woke() { reconnect() }
    @objc func lockScreen() { close(cancel: true, reason: "screen locked or asleep"); core.reset(); latest = nil }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { close(cancel: true); endMonitoringActivity(); MWStop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
}

struct ActionInput: NSViewRepresentable {
    let text: String
    let language: AppLanguage
    let textMode: Bool
    let onKeyboard: () -> Void
    let onEdit: (String, Bool) -> Void
    func makeNSView(context: Context) -> KeyBindingControl { KeyBindingControl() }
    func updateNSView(_ view: KeyBindingControl, context: Context) {
        view.configure(language: language, textMode: textMode)
        view.recorder.bindingTitle = text; view.onEdit = onEdit
        view.onKeyboard = onKeyboard
    }
}

struct SettingsView: View {
    @ObservedObject var model: Settings
    let controller: Controller
    @State private var selected: Int? = 0
    @State private var draft = ""
    @State private var textMode = false
    @State private var previewTheme: WheelTheme?
    @State private var error = ""
    @State private var showOptions = false
    @State private var showShortcuts = false
    @State private var showApplications = false
    @State private var editingGroupID: String?
    @State private var editingScene: WheelScene?
    @State private var showManualKeys = false
    @State private var showIcons = false
    @State private var confirmRemoveApplication = false
    @State private var pendingDeletion: WheelEditingTarget?
    @State private var showWheelCopy = false
    @State private var shortcutSearch = ""
    @StateObject private var shortcutCatalog = ShortcutCatalog()
    private func l(_ text: String) -> String { model.l(text) }
    var ready: Bool { model.permission && model.hookReady && model.deviceCount > 0 }
    var selectionValid: Bool { selected.map { model.slots.indices.contains($0) } ?? false }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(l("轮盘")).font(.title2.weight(.semibold)).padding(.trailing, 8)
                HStack(spacing: 8) {
                    SceneProfilePicker(model: model) { target in
                        pendingDeletion = target; confirmRemoveApplication = true
                    }
                    Button {
                        editingGroupID = nil; editingScene = nil; showApplications = true
                    } label: { Image(systemName: "plus").frame(width: 16, height: 16) }
                        .help(l("添加场景")).accessibilityLabel(l("添加场景"))
                        .sheet(isPresented: $showApplications) {
                            WheelConditionsPanel(model: model, focused: controller.lastExternalApplication,
                                editingGroupID: editingGroupID, editingScene: editingScene) { showApplications = false }
                        }
                    if model.selectedTarget != .global {
                        Button {
                            editingGroupID = model.selectedApplicationID; editingScene = model.selectedScene; showApplications = true
                        } label: { Image(systemName: "slider.horizontal.3").frame(width: 16, height: 16) }
                            .help(l("编辑场景")).accessibilityLabel(l("编辑场景"))
                        Button {
                            pendingDeletion = model.selectedTarget; confirmRemoveApplication = true
                        } label: { Image(systemName: "trash").frame(width: 16, height: 16) }
                            .help(l("删除场景")).accessibilityLabel(l("删除场景"))
                    }
                }
                Spacer(minLength: 12)
                Picker("Language", selection: $model.language) {
                    Text("中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }.labelsHidden().frame(width: 96).accessibilityLabel(l("界面语言"))
                ThemeMenu(selection: $model.theme, preview: $previewTheme, language: model.language)
                    .frame(width: 140, height: 28)
                Menu {
                    Button(l("导入设置…")) { if controller.importSettings() { selected = model.slots.isEmpty ? nil : 0; loadDraft() } }
                    Button(l("导出全部设置…")) { controller.exportSettings() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(l("导入与导出")).accessibilityLabel(l("导入与导出"))

            }.padding(24)
            Divider()
            if let profile = model.applicationWheels.first(where: { $0.id == model.selectedApplicationID }) {
                Text(profile.conditionSummary(language: model.language)).font(.caption).foregroundColor(.secondary)
                    .lineLimit(2).padding(.horizontal, 24).padding(.top, 10)
            }
            HStack(alignment: .center, spacing: 24) {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        Text(model.language == .chinese ? "\(model.slots.count) 个键位" : "\(model.slots.count) slots").foregroundColor(.secondary)
                        Spacer()
                        Button { showWheelCopy = true } label: {
                            Image(systemName: "square.and.arrow.down").frame(width: 16, height: 16)
                        }.help(l("从其他场景导入轮盘")).accessibilityLabel(l("从其他场景导入轮盘"))
                            .disabled(model.profileTargets.count < 2)
                        Button(action: remove) { Image(systemName: "minus").frame(width: 16, height: 16) }.disabled(!selectionValid).help(l("删除选中的键位")).accessibilityLabel(l("删除选中的键位"))
                        Button(action: add) { Image(systemName: "plus").frame(width: 16, height: 16) }.help(l("添加键位")).accessibilityLabel(l("添加键位"))
                    }.padding(.horizontal, 26)
                    Text(l((previewTheme ?? model.theme).detail)).font(.caption).foregroundColor(.secondary)
                        .frame(height: 18)
                    WheelEditor(model: model, selected: $selected, previewTheme: previewTheme, add: add, insert: insert).frame(width: 440, height: 390)

                    HStack {
                        Text(l("点击扇区编辑 · 拖到间隙插入\n拖动外圈手柄旋转")).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(l("预览动效")) { controller.preview() }.help(l("移动鼠标体验主题，点击关闭；不会执行按键"))
                        Button(l("复位")) { model.rotation = 0 }.disabled(abs(model.rotation) < 0.001)
                    }.padding(.horizontal, 12)
                }.frame(width: 440)
                Divider()
                editor.frame(width: 280)
            }.padding(.horizontal, 24).padding(.vertical, 22)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Label(ready ? (model.enabled ? l("已就绪") : l("已暂停")) : l("需要辅助功能权限"), systemImage: ready ? "checkmark.circle" : "exclamationmark.circle").font(.callout).foregroundColor(.secondary)
                Spacer()
                Button { showOptions.toggle() } label: { Label(l("其他设置"), systemImage: "gearshape") }
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) { options.frame(width: 430).padding(16) }
                Button(l("完成设置")) { controller.settingsWindow.performClose(nil) }
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .alert(l("删除此场景？"), isPresented: $confirmRemoveApplication) {
            Button(l("取消"), role: .cancel) { pendingDeletion = nil }
            Button(l("删除场景"), role: .destructive) {
                if let pendingDeletion { model.removeProfile(pendingDeletion) }
                pendingDeletion = nil
            }
        } message: {
            Text(pendingDeletion.map { model.profileTitle($0) } ?? "")
        }
        .sheet(isPresented: $showWheelCopy) {
            WheelCopyPanel(model: model, didCopy: {
                selected = model.slots.isEmpty ? nil : 0; loadDraft()
            }) { showWheelCopy = false }
        }
        .tint(.primary)
        .onAppear { if model.slots.isEmpty { selected = nil }; loadDraft() }
        .onChange(of: model.language) { _ in KeyRecorderButton.active?.stop(); loadDraft() }
        .onChange(of: selected) { _ in KeyRecorderButton.active?.stop(); showManualKeys = false; showShortcuts = false; showIcons = false; loadDraft() }
        .onChange(of: model.selectedTarget) { _ in
            KeyRecorderButton.active?.stop(); showManualKeys = false; showShortcuts = false; showIcons = false
            selected = model.slots.isEmpty ? nil : 0; loadDraft()
        }
    }
    @ViewBuilder var editor: some View {
        if let index = selected, model.slots.indices.contains(index) {
            let editingTarget = model.selectedTarget
            VStack(alignment: .leading, spacing: 12) {
                Text(l("键位内容")).font(.headline)
                HStack(spacing: 8) {
                    ActionInput(text: textMode ? l("快捷输入文字") : draft, language: model.language, textMode: textMode, onKeyboard: { showManualKeys = true }, onEdit: { value, isText in
                        textMode = isText
                        if isText {
                            if QuickTextBinding.decode(model.slots[index]) == nil { draft = "" }
                            saveDraft()
                        } else { draft = value; saveDraft(); loadDraft() }
                    }).frame(height: 28)
                    Button {
                        shortcutSearch = ""; showShortcuts.toggle()
                    } label: { Image(systemName: "square.stack.3d.up").frame(width: 18, height: 18) }
                        .help(l("添加现有快捷指令")).accessibilityLabel(l("添加现有快捷指令"))
                        .popover(isPresented: $showShortcuts, arrowEdge: .trailing) {
                            shortcutPicker(index).frame(width: 320, height: 390).padding(16)
                                .onAppear { shortcutCatalog.refresh() }
                        }
                }
                .sheet(isPresented: $showManualKeys) {
                    ManualKeyPicker(initial: model.actions[index], language: model.language, dismiss: { showManualKeys = false }) { value in
                        _ = model.updateSlot(index, input: value, textMode: false); loadDraft(); showManualKeys = false
                    }
                }
                if textMode {
                    Text(l("自定义短语或文字")).font(.callout)
                    QuickTextEditor(text: Binding(get: { draft }, set: {
                        guard selected == index, model.selectedTarget == editingTarget else { return }
                        draft = $0; saveDraft()
                    }), accessibilityLabel: l("自定义短语或文字"))
                        .id(QuickTextDocument(target: editingTarget, slot: index))
                        .font(.body).padding(5).frame(height: 76)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        .accessibilityLabel(l("自定义短语或文字"))
                    Text(l("触发时输入以下文字，支持多行、中文和 emoji。"))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle(l("输入后自动按 Enter（发送）"), isOn: Binding(get: {
                        QuickTextBinding.decode(model.slots[index])?.sendReturn ?? false
                    }, set: { enabled in
                        guard selected == index, model.selectedTarget == editingTarget,
                              let binding = QuickTextBinding.decode(model.slots[index]) else { return }
                        _ = model.updateSlot(index, input: binding.text, textMode: true, sendReturn: enabled)
                    }))
                    Text(l("文字输入完成后按一次 Enter；是否发送取决于目标应用的 Enter 设置。"))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(l("点击录制单键或组合键；修饰键松开后保存。按键被语音输入等功能占用时，可用“手动配置按键”。"))
                        .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.actions[index].operation == .settings {
                    Label(l("选中后打开 Orvia 设置"), systemImage: "gearshape").font(.callout).foregroundColor(.secondary)
                }
                if model.actions[index].operation == .clearText || model.actions[index].operation == .virtualKeyboard {
                    Text(l(model.actions[index].operation == .clearText
                        ? "触发轮盘时清空当前聚焦的文本框；在这里选择只保存绑定。"
                        : "触发轮盘时打开可直接输入的悬浮键盘；手动配置按键请使用菜单中的独立选项。"))
                        .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let shortcut = model.actions[index].systemShortcutReference {
                    Label(l("快捷指令：") + shortcut.name, systemImage: "square.stack.3d.up").font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !error.isEmpty { Text(error).font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
                Picker(l("触发方式"), selection: Binding(get: { model.trigger(at: index) }, set: { model.setTrigger($0, at: index) })) {
                    ForEach(TriggerMode.allCases.filter { $0 != .whileInside || model.actions[index].canHold }) { mode in
                        Text(l(mode.title)).tag(mode)
                    }
                }.pickerStyle(.menu).accessibilityLabel(l("此键位触发方式"))
                Text(l(model.trigger(at: index).detail)).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                appearanceEditor(index)
                Spacer(minLength: 16)
                Divider()
                HStack {
                    Spacer()
                    Text(error.isEmpty ? l("自动保存") : l("尚未保存")).font(.callout).foregroundColor(.secondary)
                }
            }.padding(.vertical, 18)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "plus.circle").font(.largeTitle).foregroundColor(.secondary)
                Text(l("添加一个键位开始设置")).foregroundColor(.secondary)
                Button(l("添加键位"), action: add)
            }.frame(maxHeight: .infinity)
        }
    }
    private func shortcutPicker(_ index: Int) -> some View {
        let choices = shortcutCatalog.shortcuts.filter { shortcutSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(shortcutSearch) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(l("添加现有快捷指令")).font(.headline)
            TextField(l("搜索快捷指令"), text: $shortcutSearch).textFieldStyle(.roundedBorder)
            if shortcutCatalog.loading {
                Spacer(); HStack { Spacer(); ProgressView(l("正在读取…")); Spacer() }; Spacer()
            } else if let error = shortcutCatalog.error {
                Spacer(); Text(error).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true); Spacer()
            } else if choices.isEmpty {
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text(shortcutCatalog.shortcuts.isEmpty ? l("尚无快捷指令") : l("没有匹配的快捷指令")).font(.headline)
                    if shortcutCatalog.shortcuts.isEmpty { Text(l("先在“快捷指令”App 中添加，回来刷新后即可选择。")).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(choices) { shortcut in
                            Button {
                                guard model.slots.indices.contains(index) else { return }
                                model.assignShortcut(shortcut, at: index); loadDraft(); showShortcuts = false
                            } label: {
                                HStack {
                                    Image(systemName: "square.stack.3d.up").foregroundColor(.secondary)
                                    Text(shortcut.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    if model.actions[index].systemShortcutReference?.id == shortcut.id { Image(systemName: "checkmark").foregroundColor(.primary) }
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button(l("打开快捷指令")) {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Shortcuts.app"), configuration: NSWorkspace.OpenConfiguration())
                }
                Spacer()
                Button(l("刷新")) { shortcutCatalog.refresh() }.disabled(shortcutCatalog.loading)
            }
        }
    }
    private func appearanceBinding<Value>(_ index: Int, _ key: WritableKeyPath<SlotAppearance, Value>) -> Binding<Value> {
        Binding(get: { model.appearance(at: index)[keyPath: key] }, set: { value in
            var style = model.appearance(at: index); style[keyPath: key] = value
            model.setAppearance(style, at: index)
        })
    }
    private func appearanceText(_ index: Int, _ key: WritableKeyPath<SlotAppearance, String?>) -> Binding<String> {
        Binding(get: { model.appearance(at: index)[keyPath: key] ?? "" }, set: { value in
            var style = model.appearance(at: index); style[keyPath: key] = value.isEmpty ? nil : value
            model.setAppearance(style, at: index)
        })
    }
    private func appearanceEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l("轮盘显示")).font(.headline)
                Spacer()
                Button(l("恢复默认")) { model.resetAppearance(at: index) }
                    .buttonStyle(.link).disabled(!model.appearance(at: index).hasCustomAppearance)
            }
            Toggle(l("显示名称"), isOn: appearanceBinding(index, \.showName))
            TextField(model.actions[index].displayLabel(model.language), text: appearanceText(index, \.name))
                .textFieldStyle(.roundedBorder).accessibilityLabel(l("自定义显示名称"))
            Toggle(l("显示图标"), isOn: appearanceBinding(index, \.showIcon))
            HStack(spacing: 8) {
                TextField(model.language.keyLabel(l(model.actions[index].glyph)), text: appearanceText(index, \.icon))
                    .textFieldStyle(.roundedBorder).accessibilityLabel(l("自定义图标"))
                Button { KeyRecorderButton.active?.stop(); showIcons = true } label: { Image(systemName: "square.grid.2x2") }
                    .frame(width: 24).accessibilityLabel(l("选择图标")).help(l("选择图标"))
                    .sheet(isPresented: $showIcons) {
                        SystemIconPicker(language: model.language, current: model.appearance(at: index).icon ?? model.actions[index].glyph, dismiss: { showIcons = false }) { symbol in
                            guard model.slots.indices.contains(index) else { showIcons = false; return }
                            appearanceText(index, \.icon).wrappedValue = symbol; showIcons = false
                        }
                    }
            }
            Text(l("名称和图标可分别隐藏。图标支持 emoji、符号或系统图标名称；留空使用默认值。"))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var options: some View {
        Form {
            Section(l("手势")) {
                Toggle(l("启用轮盘"), isOn: $model.enabled)
                HStack {
                    Text(l("长按时间"))
                    Spacer()
                    Slider(value: $model.hold, in: Settings.minimumHold...Settings.maximumHold, step: 0.05).frame(width: 120).accessibilityLabel(l("长按时间"))
                    Stepper(value: $model.hold, in: Settings.minimumHold...Settings.maximumHold, step: 0.05) {
                        Text(String(format: model.language == .chinese ? "%.2f 秒" : "%.2f s", model.hold)).monospacedDigit()
                    }.accessibilityLabel(l("长按时间微调"))
                }.accessibilityElement(children: .contain)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(l("选择移动距离"))
                        Spacer()
                        Slider(value: $model.travel, in: 0.07...0.25, step: 0.01).frame(width: 150).accessibilityLabel(l("选择移动距离"))
                        Text(model.travel < 0.12 ? l("短") : model.travel > 0.18 ? l("长") : l("适中"))
                    }.accessibilityElement(children: .contain)
                    Text(l("轮盘打开后，手指需要移动多远才能选中扇区。\n短：轻微移动即可；长：需移动更多，减少误选。"))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .contain)
            }
            Section(l("连接与权限")) {
                LabeledContent(l("触控板"), value: model.deviceCount > 0 ? l("已连接") : l("未连接"))
                LabeledContent(l("辅助功能"), value: model.permission && model.hookReady ? l("已允许") : l("未允许"))
                HStack {
                    Button(model.permission ? l("查看辅助功能权限…") : l("允许辅助功能…")) { controller.authorize() }
                    Spacer()
                    Button(l("重新检测")) { controller.reconnect() }
                }
            }
        }.formStyle(.grouped).frame(height: 410)
    }
    func loadDraft() {
        error = ""
        guard let index = selected, model.slots.indices.contains(index) else { draft = ""; textMode = false; return }
        let value = model.slots[index]
        let binding = QuickTextBinding.decode(value)
        textMode = binding != nil
        draft = binding?.text ?? RecordedKey.decode(value).map { model.language.keyLabel($0.label) } ?? SystemShortcut.decode(value)?.name ?? KeyAction.all.first { $0.id == value }.map { l($0.label) } ?? value
    }
    func saveDraft() {
        guard let index = selected, model.slots.indices.contains(index) else { return }
        error = model.updateSlot(index, input: draft, textMode: textMode) ? "" : l("快捷键尚未完整或无法识别，原键位已保留。")
    }
    func insert(_ source: Int, _ boundary: Int) {
        guard let destination = model.insertSlot(source, before: boundary) else { return }
        selected = destination; loadDraft()
    }
    func add() {
        model.slots.append(""); selected = model.slots.count - 1; loadDraft()
    }
    func remove() {
        guard let index = selected, model.slots.indices.contains(index) else { return }
        model.removeSlot(index)
        selected = model.slots.isEmpty ? nil : min(index, model.slots.count - 1)
        loadDraft()
    }
}

// Opt-in integration verification uses a disposable text view. The separate
// --shortcut-test button deliberately tests the user's Command+F1 global hotkey.
final class QuickTextTestState: ObservableObject {
    @Published var text = "前文：" { didSet { onSave?(text) } }
    @Published var refresh = 0
    var onSave: ((String) -> Void)?
}
struct QuickTextTestHost: View {
    @ObservedObject var state: QuickTextTestState
    var body: some View {
        VStack {
            QuickTextEditor(text: $state.text, accessibilityLabel: "临时快捷文字测试")
            Text(String(state.refresh))
        }.frame(width: 280, height: 100)
    }
}
final class IntegrationDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let text = NSTextView()
    let sender = KeySender()
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var recorded: [(CGEventType, Int64, UInt64)] = []
    var modifierTap: CFMachPort?
    var modifierSource: CFRunLoopSource?
    var checks = 0
    var voiceButton: NSButton?
    var wheelController: Controller?
    lazy var inputKeyboard = RuntimeKeyboardController(sender: sender)
    @objc func testCommandF1() {
        guard sender.available else { return }
        let saved = UserDefaults.standard.stringArray(forKey: "slots") ?? []
        let action = saved.map(KeyAction.find).first { $0.key == 122 && $0.flags.contains(.maskCommand) && !$0.held }
            ?? KeyAction.find(RecordedKey.capture(key: 122, flags: .maskCommand).storedValue)
        sender.tap(action)
        print("Command+F1 sent through KeySender (key=\(action.key), flags=\(action.flags.rawValue))")
        fflush(stdout)
    }
    @objc func testVoiceKey() {
        guard sender.available else { voiceButton?.title = "请先允许辅助功能权限"; return }
        window.makeFirstResponder(text)
        voiceButton?.isEnabled = false
        voiceButton?.title = "右 Option 已按下；5 秒后自动释放"
        sender.hold(KeyAction.find("option"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.sender.release()
            self.voiceButton?.title = "测试右 Option（保持 5 秒）"
            self.voiceButton?.isEnabled = true
        }
    }
    func report(_ success: Bool, _ message: String) {
        print("\(success ? "PASS" : "FAIL"): \(message)")
        if !success {
            for event in recorded { print("Event type=\(event.0.rawValue) key=\(event.1) flags=\(String(event.2, radix: 16))") }
            fflush(stdout); exit(1)
        }
        checks += 1
    }
    func later(_ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
                self.report(false, "Test window lost focus; no further keys sent"); return
            }
            body()
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--text-editor-test") {
            verifyQuickTextEditor()
            return
        }
        if CommandLine.arguments.contains("--idle-gesture-test") {
            verifyIdleGestures()
            print("PASS: \(checks) stationary gesture lifecycle checks (no key injection)"); fflush(stdout)
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--login-item-test") {
            let before = SMAppService.mainApp.status
            guard before == .notRegistered || before == .notFound else {
                print("Login item already configured (\(before.rawValue)); preserved without modification")
                fflush(stdout); NSApp.terminate(nil); return
            }
            do {
                try SMAppService.mainApp.register()
                let registered = SMAppService.mainApp.status
                try SMAppService.mainApp.unregister()
                report(registered == .enabled || registered == .requiresApproval, "System accepts login-item registration")
                report(SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound, "Unchecking restores unregistered login-item state")
                print("Login item remains OFF; no logout/reboot was performed")
            } catch {
                try? SMAppService.mainApp.unregister()
                report(false, "Login-item registration test: \(error.localizedDescription)")
            }
            fflush(stdout); NSApp.terminate(nil); return
        }
        if !CommandLine.arguments.contains("--voice-test") { report(AXIsProcessTrusted(), "Accessibility authorized") }
        let placementPanel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if !CommandLine.arguments.contains("--voice-test") {
            for point in [NSScreen.main!.frame.origin, CGPoint(x: NSScreen.main!.frame.midX, y: NSScreen.main!.frame.midY)] {
                placementPanel.setFrameOrigin(wheelOrigin(cursor: point, size: placementPanel.frame.size))
                report(abs(placementPanel.frame.midX - point.x) < 0.1 && abs(placementPanel.frame.midY - point.y) < 0.1, "Native panel center remains at cursor (\(point))")
            }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Orvia · 临时按键验证窗口"
        text.frame = window.contentView!.bounds; text.autoresizingMask = [.width, .height]
        text.font = .systemFont(ofSize: 22); text.isRichText = false
        text.string = "test"; text.setSelectedRange(NSRange(location: 4, length: 0))
        window.contentView = text; window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text); NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--quick-text-send-test") {
            let phrase = String(repeating: "完整文字🙂", count: 8) + "\n第二行"
            text.string = ""; text.setSelectedRange(NSRange(location: 0, length: 0))
            // Allow the temporary test window to finish activation before the
            // normal focus guard permits any synthetic input.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.later {
                self.sender.tap(KeyAction.find(QuickTextBinding(text: phrase, sendReturn: true).storedValue))
                self.later {
                    self.report(self.text.string == phrase + "\n", "Full multiline Unicode text arrives before exactly one Return")
                    self.text.string = ""; self.text.setSelectedRange(NSRange(location: 0, length: 0))
                    self.sender.tap(KeyAction.find(QuickTextBinding(text: phrase).storedValue))
                    self.later {
                        self.report(self.text.string == phrase, "Disabled automatic Return inserts only the phrase")
                        self.sender.tap(KeyAction.find(QuickTextBinding(text: "", sendReturn: true).storedValue))
                        self.later {
                            self.report(self.text.string == phrase, "Empty automatic-send draft sends neither text nor Return")
                            print("PASS: \(self.checks) quick-text send integration checks (temporary native window only)"); fflush(stdout)
                            NSApp.terminate(nil)
                        }
                    }
                }
            } }
            return
        }
        if CommandLine.arguments.contains("--scene-test") {
            later { self.verifySceneRouting() }
            return
        }
        if CommandLine.arguments.contains("--gesture-test") {
            later { self.verifyGestureAvailability() }
            return
        }
        if CommandLine.arguments.contains("--shortcut-test") {
            text.string = "测试当前配置的 Command＋F1 截图快捷键。"
            text.frame = NSRect(x: 16, y: 90, width: 518, height: 150)
            text.autoresizingMask = []
            let container = NSView(frame: window.contentView!.bounds)
            text.removeFromSuperview(); container.addSubview(text)
            let button = NSButton(title: "测试 Command＋F1", target: self, action: #selector(testCommandF1))
            button.bezelStyle = .rounded; button.frame = NSRect(x: 150, y: 25, width: 250, height: 40)
            container.addSubview(button)
            window.contentView = container
            return
        }
        if CommandLine.arguments.contains("--input-actions-test") {
            text.string = "临时文本🙂\nSecond line"; text.setSelectedRange(NSRange(location: 3, length: 0))
            later {
                self.report(InputActions.clearFocusedText(using: self.sender), "Clear accepts focused native text view")
                self.later {
                    self.report(self.text.string.isEmpty, "Clear removes full multiline text, not just selection")
                    let button = NSButton(title: "Non-text target", target: nil, action: nil)
                    button.frame = NSRect(x: 0, y: 0, width: 150, height: 30)
                    self.text.addSubview(button); self.window.makeFirstResponder(button)
                    self.later {
                        self.report(!InputActions.clearFocusedText(using: self.sender), "Clear rejects a non-text target")
                        self.window.makeFirstResponder(self.text)
                        self.inputKeyboard.show(language: .chinese)
                        self.report(self.inputKeyboard.isVisible, "Runtime keyboard is visible")
                        self.later {
                            self.report(NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "Runtime keyboard preserves typing target focus")
                            self.inputKeyboard.press(36)
                            self.later {
                                self.report(self.text.string == "\n", "Runtime keyboard enters Return into focused field")
                                self.inputKeyboard.press(55); self.inputKeyboard.press(0)
                                self.later {
                                    self.report(self.text.selectedRange().length == 1 && self.inputKeyboard.modifiers.isEmpty, "Runtime keyboard sends Command+A and releases modifier selection")
                                    self.inputKeyboard.press(51)
                                    self.later {
                                        self.report(self.text.string.isEmpty, "Runtime keyboard deletes selected text")
                                        print("PASS: \(self.checks) input-action integration checks"); fflush(stdout)
                                        if !CommandLine.arguments.contains("--keep-open") { NSApp.terminate(nil) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return
        }
        if CommandLine.arguments.contains("--voice-test") {
            window.title = "Orvia · 右 Option 验证"
            text.frame = NSRect(x: 16, y: 70, width: 518, height: 170)
            text.autoresizingMask = []
            text.string = "请在输入法菜单中选中微信输入法，再点击下方测试按钮。"
            let container = NSView(frame: window.contentView!.bounds)
            text.removeFromSuperview(); container.addSubview(text)
            let button = NSButton(title: "测试右 Option（保持 5 秒）", target: self, action: #selector(testVoiceKey))
            button.bezelStyle = .rounded; button.frame = NSRect(x: 130, y: 20, width: 290, height: 32)
            container.addSubview(button); voiceButton = button
            window.contentView = container; window.makeFirstResponder(text)
            return
        }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            let test = Unmanaged<IntegrationDelegate>.fromOpaque(info!).takeUnretainedValue()
            if event.getIntegerValueField(.eventSourceUserData) == KeySender.eventTag && type != .flagsChanged {
                test.recorded.append((type, event.getIntegerValueField(.keyboardEventKeycode), event.flags.rawValue))
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        report(tap != nil, "Event tap created")
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap!, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)
        // All physical keys use HID; observe modifier releases independently.
        modifierTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue, callback: { _, type, event, info in
            let test = Unmanaged<IntegrationDelegate>.fromOpaque(info!).takeUnretainedValue()
            if type == .flagsChanged { test.recorded.append((type, event.getIntegerValueField(.keyboardEventKeycode), event.flags.rawValue)) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        report(modifierTap != nil, "Modifier event tap created")
        modifierSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, modifierTap!, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), modifierSource, .commonModes)
        CGEvent.tapEnable(tap: modifierTap!, enable: true)
        if CommandLine.arguments.contains("--key-sequence-test") {
            later { self.verifyKeySequences(index: 0) }
            return
        }
        later {
            self.verifyRecorder()
            self.sender.tap(KeyAction.find("space"))
            self.later {
                self.report(self.text.string == "test ", "Space delivered to the focused text view")
                self.sender.tap(KeyAction.find("delete"))
                self.later {
                    self.report(self.text.string == "test", "Backspace delivered")
                    self.sender.tap(KeyAction.find("Command+A"))
                    self.later {
                        self.report(self.text.selectedRange().length == 4, "Freely entered Command+A selected text")
                        self.sender.tap(KeyAction.find("text:你好🙂"))
                        self.later {
                            self.report(self.text.string == "你好🙂", "Custom Unicode text delivered including surrogate pair")
                            self.verifyWheelModes()
                        }
                    }
                }
            }
        }
    }
    func verifyRecorder() {
        let recorder = KeyRecorderButton(frame: NSRect(x: 10, y: 10, width: 250, height: 28))
        window.contentView?.addSubview(recorder)
        var result: RecordedKey?
        recorder.onRecord = { result = RecordedKey.decode($0) }
        func input(_ type: CGEventType, _ key: UInt16, _ flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
            event.type = type; event.flags = flags
            _ = recorder.consume(type: type, event: event)
        }
        recorder.beginRecording()
        input(.flagsChanged, 61, CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40))
        report(result == nil && recorder.recording, "Right Option waits for release during recording")
        input(.flagsChanged, 61, [])
        report(result?.key == 61 && result?.modifier == true && !recorder.recording, "Right Option release records the right physical modifier")
        report(result!.flags & 0x40 != 0, "Recorded Right Option retains device-side flag")
        result = nil; recorder.beginRecording()
        input(.flagsChanged, 59, .maskControl); input(.flagsChanged, 60, [.maskControl, .maskShift])
        input(.keyDown, 40, [.maskControl, .maskShift])
        report(result?.label == "⌃⇧K" && result?.key == 40, "Recording combines held modifiers with physical K")
        result = nil; recorder.beginRecording(); input(.keyDown, 49, .maskCommand)
        report(result?.label == "⌘空格", "Reserved shortcut encoding retains Command+Space")
        result = nil; recorder.beginRecording(); input(.keyDown, 36, [])
        report(result?.key == 36, "Return records as a key, without submitting the settings window")
        result = nil; recorder.beginRecording(); input(.keyDown, 53, [])
        report(result?.key == 53, "Escape is recordable")
        result = nil; recorder.beginRecording(); window.makeFirstResponder(text)
        report(!recorder.recording && KeyRecorderButton.active == nil && result == nil, "Leaving recording cancels without replacing the binding")
        recorder.removeFromSuperview(); window.makeFirstResponder(text)
    }
    func verifyOption() {
                        self.sender.hold(KeyAction.find("option"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.sender.release()
                            self.later {
                                self.report(self.recorded.contains { $0.0 == .flagsChanged && $0.1 == 61 && $0.2 & CGEventFlags.maskAlternate.rawValue != 0 && $0.2 & 0x40 != 0 }, "Right Option down includes right-side modifier flag")
                                self.report(self.recorded.contains { $0.0 == .flagsChanged && $0.1 == 61 && $0.2 & CGEventFlags.maskAlternate.rawValue == 0 }, "Right Option released")
                                print("PASS: \(self.checks) live integration checks")
                                fflush(stdout); NSApp.terminate(nil)
                            }
                        }
    }
    func verifyQuickTextEditor() {
        let suite = "local.magicwheel.text-editor-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let settings = Settings(defaults: defaults)
        settings.slots = ["text:前文："]
        let state = QuickTextTestState()
        state.onSave = { _ = settings.updateSlot(0, input: $0, textMode: true) }
        let host = NSHostingView(rootView: QuickTextTestHost(state: state))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Orvia · 临时文字输入验证"
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func findEditor(_ view: NSView) -> QuickTextView? {
            if let editor = view as? QuickTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            host.layoutSubtreeIfNeeded()
            guard let editor = findEditor(host) else { self.report(false, "Native editor is mounted"); return }
            self.window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            var steps: [() -> Void] = []
            var savedSelection = editor.selectedRange()
            for phrase in ["语", "语音输入", "语音输入一整句话"] {
                steps.append {
                    editor.setMarkedText(phrase, selectedRange: NSRange(location: (phrase as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    // Some input clients notify during provisional updates.
                    editor.didChangeText()
                    self.report(state.text == "前文：" && settings.slots[0] == "text:前文：", "Provisional text is not persisted")
                    state.refresh += 1
                }
                steps.append {
                    self.report(findEditor(host) === editor && editor.string == "前文：" + phrase && editor.markedRange() == NSRange(location: 3, length: (phrase as NSString).length), "Settings refresh preserves native client, prefix and marked range")
                }
            }
            steps.append {
                editor.insertText("语音输入一整句话。", replacementRange: NSRange(location: NSNotFound, length: 0))
                state.refresh += 1
            }
            steps.append {
                self.report(editor.string == "前文：语音输入一整句话。" && state.text == editor.string && settings.slots[0] == "text:" + editor.string, "Final recognition saves the entire phrase")
                savedSelection = editor.selectedRange()
                state.refresh += 1
            }
            steps.append {
                self.report(editor.selectedRange() == savedSelection, "Model echo retains the insertion point")
                editor.insertText("\n第二句🙂", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            steps.append {
                self.report(state.text == "前文：语音输入一整句话。\n第二句🙂", "Successive committed segments append with newline and emoji")
                editor.setSelectedRange(NSRange(location: 3, length: 4))
                editor.setMarkedText("口述", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                state.refresh += 1
            }
            steps.append {
                self.report(editor.string == "前文：口述一整句话。\n第二句🙂", "Composition replaces only the selected phrase")
                editor.unmarkText()
            }
            steps.append {
                self.report(state.text == editor.string && Settings(defaults: defaults).slots[0] == "text:" + editor.string, "Unmark-only commit persists and survives reload")
                let end = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
                editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
                editor.setSelectedRange(NSRange(location: end, length: 3))
                editor.deleteBackward(nil)
            }
            steps.append {
                self.report(editor.string == "前文：口述一整句话。\n第二句🙂" && state.text == editor.string, "Typing and deleting do not discard earlier text")
                state.text = "另一个键位"
            }
            steps.append {
                self.report(editor.string == "另一个键位" && !editor.hasMarkedText(), "External document changes load correctly")
            }
            func run(_ index: Int) {
                guard index < steps.count else {
                    defaults.removePersistentDomain(forName: suite)
                    print("PASS: \(self.checks) native quick-text checks (no key injection)"); fflush(stdout)
                    NSApp.terminate(nil); return
                }
                steps[index]()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { host.layoutSubtreeIfNeeded(); run(index + 1) }
            }
            run(0)
        }
    }
    func verifySceneRouting() {
        let suite = "local.magicwheel.scene-integration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let settings = Settings(defaults: defaults)
        settings.slots = ["", ""]
        settings.addApplication(id: Bundle.main.bundleIdentifier!, name: "Test", path: "")
        settings.slots = [""]; settings.rotation = 0.2
        settings.addScene(.textInput)
        settings.slots = ["", "", ""]; settings.rotation = 0.8
        settings.selectApplication(nil)
        let controller = Controller(settings: settings)
        wheelController = controller; controller.setupPanel()
        report(InputActions.isTextInputFocused(in: NSWorkspace.shared.frontmostApplication), "Native editable text view matches text-input scene")
        controller.showWheel(demo: false)
        report(controller.targetActions.count == 3 && controller.targetRotation == 0.8, "Controller chooses scene over app while editor is global")
        settings.selectTarget(.scene(.textInput)); settings.slots = ["", "", "", ""]
        report(controller.targetActions.count == 3, "Open scene wheel keeps its configuration snapshot")
        controller.close(cancel: true)
        let button = NSButton(title: "Non-text target", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 160, height: 30)
        text.addSubview(button); window.makeFirstResponder(button)
        later {
            self.report(!InputActions.isTextInputFocused(in: NSWorkspace.shared.frontmostApplication), "Button focus does not match text-input scene")
            controller.showWheel(demo: false)
            self.report(controller.targetActions.count == 1 && controller.targetRotation == 0.2, "Leaving text input restores app wheel")
            controller.close(cancel: true)
            controller.showWheel(demo: true)
            self.report(controller.targetActions.count == 4, "Preview uses selected scene independently of focus")
            controller.close(cancel: true)
            self.window.makeFirstResponder(self.text)
            settings.removeSelectedScene()
            self.later {
                controller.showWheel(demo: false)
                self.report(controller.targetActions.count == 1, "Unconfigured text scene falls back to app wheel")
                controller.close(cancel: true)
                let app = WheelApplication(id: Bundle.main.bundleIdentifier!, name: "Test", path: "")
                self.report(settings.setWheelRule(id: nil, name: "General input", applications: [], scenes: [.textInput], mode: .all), "Create general named text scene")
                settings.slots = ["", ""]
                self.report(settings.setWheelRule(id: nil, name: "App input", applications: [app], scenes: [.textInput], mode: .all), "Create app-scoped named text scene")
                settings.slots = ["", "", "", "", ""]; settings.rotation = 1.0
                settings.selectTarget(.global)
                controller.showWheel(demo: false)
                self.report(controller.targetActions.count == 5 && controller.targetRotation == 1.0, "Live controller detects text focus for combined scene with no legacy scene")
                controller.close(cancel: true)
                self.window.makeFirstResponder(button)
                self.later {
                    controller.showWheel(demo: false)
                    self.report(controller.targetActions.count == 1, "Combined scene requires actual text focus")
                    controller.close(cancel: true)
                    defaults.removePersistentDomain(forName: suite)
                    print("PASS: \(self.checks) scene integration checks"); fflush(stdout)
                    NSApp.terminate(nil)
                }
            }
        }
    }
    func configureWheel(_ actions: [KeyAction], modes: [TriggerMode]) {
        let controller = wheelController!
        controller.close(cancel: true); controller.showWheel(demo: false)
        controller.targetActions = actions; controller.targetTriggers = modes
        controller.wheel.actions = actions; controller.wheel.triggerModes = modes
    }
    func selectSector(_ index: Int) {
        let controller = wheelController!
        let angle = controller.targetRotation + Double(index) * 2 * .pi / Double(controller.targetActions.count)
        controller.move(WheelVector(x: sin(angle), y: cos(angle)))
        controller.commitSelection()
    }
    func verifyWheelModes() {
        let controller = Controller(); wheelController = controller
        controller.setupPanel(); controller.settings.permission = AXIsProcessTrusted()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
        text.string = "mode"; text.setSelectedRange(NSRange(location: 4, length: 0))
        configureWheel([KeyAction.find("space"), KeyAction.find("delete")], modes: [.onEntry, .onRelease])
        report(controller.cursorHidden && WheelCursor.systemVisible == false, "Actual cursor invisible while wheel is visible")
        selectSector(0)
        later {
            self.report(self.text.string == "mode " && controller.wheel.feedback == .fired, "Entry sector taps and reports fired (text=\(self.text.string.debugDescription), phase=\(controller.wheel.feedback))")
            controller.commitSelection()
            self.later {
                self.report(self.text.string == "mode ", "Remaining in entry sector does not repeat")
                self.selectSector(1)
                self.later {
                    self.report(self.text.string == "mode " && controller.wheel.feedback == .releaseReady, "Release sector arms without typing")
                    controller.close(cancel: false)
                    self.later {
                        self.report(self.text.string == "mode", "Final release sector executes only when wheel closes")
                        self.report(!controller.cursorHidden && controller.cursorRestoreSucceeded, "Cursor restored after normal close")
                        self.verifyHeldOrdinaryKey()
                    }
                }
            }
        }
    }
    func verifyHeldOrdinaryKey() {
        let controller = wheelController!
        let firstEvent = recorded.count
        configureWheel([KeyAction.find("space")], modes: [.whileInside]); selectSector(0)
        later {
            let events = Array(self.recorded.dropFirst(firstEvent)).filter { $0.1 == 49 }
            self.report(events.filter { $0.0 == .keyDown }.count == 1 && events.filter { $0.0 == .keyUp }.isEmpty && controller.wheel.feedback == .holding, "Ordinary hold sends key-down without premature key-up")
            controller.move(WheelVector())
            self.later {
                let released = Array(self.recorded.dropFirst(firstEvent)).filter { $0.1 == 49 && $0.0 == .keyUp }
                self.report(released.count == 1 && controller.wheel.feedback == .idle, "Moving out releases held key and clears press feedback")
                controller.close(cancel: true); controller.close(cancel: true)
                self.report(!controller.cursorHidden && controller.cursorRestoreSucceeded, "Repeated cancellation restores cursor without unbalanced hide count")
                self.verifyFocusRelease()
            }
        }
    }
    func verifyFocusRelease() {
        let controller = wheelController!, firstEvent = recorded.count
        configureWheel([KeyAction.find("space")], modes: [.whileInside]); selectSector(0)
        later {
            controller.targetPID = -1
            controller.frontmostChanged()
            self.later {
                let releases = self.recorded.dropFirst(firstEvent).filter { $0.1 == 49 && $0.0 == .keyUp }
                self.report(releases.count == 1 && !controller.wheelVisible && !controller.cursorHidden, "Focus-change handler releases held key and restores cursor exactly once")
                self.verifyCanceledRelease()
            }
        }
    }
    func verifyCanceledRelease() {
        let controller = wheelController!, before = text.string
        configureWheel([KeyAction.find("space")], modes: [.onRelease]); selectSector(0)
        controller.close(cancel: true)
        later {
            self.report(self.text.string == before, "Canceled gesture never executes pending release action")
            self.configureWheel([KeyAction.find("space")], modes: [.onRelease]); self.selectSector(0)
            controller.move(WheelVector()); controller.close(cancel: false)
            self.later {
                self.report(self.text.string == before, "Returning to center before exit disarms release action")
                self.configureWheel([KeyAction.find("space")], modes: [.onRelease]); self.selectSector(0)
                controller.targetPID = -1; controller.close(cancel: false)
                self.later {
                    self.report(self.text.string == before && !controller.cursorHidden, "Changed target prevents pending action and restores cursor")
                    self.configureWheel([KeyAction.find("settings")], modes: [.onRelease]); self.selectSector(0)
                    controller.close(cancel: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.report(controller.settingsWindow?.isVisible == true && !controller.wheelVisible, "Wheel operation opens its own settings after release")
                        self.report(self.text.string == before, "App operation does not emit an unintended key")
                        controller.settingsWindow.orderOut(nil)
                        self.window.makeKeyAndOrderFront(nil); self.window.makeFirstResponder(self.text)
                        NSApp.activate(ignoringOtherApps: true)
                        self.later { self.verifySystemShortcuts() }
                    }
                }
            }
        }
    }
    func verifySystemShortcuts() {
        let controller = wheelController!
        let shortcut = SystemShortcut(identifier: "7E42B2A6-580A-4B58-8E1B-95B913533650", name: "验证用快捷指令")!
        let action = KeyAction.find(shortcut.storedValue), before = text.string
        var requests: [[String]] = []
        var pending: ((Result<String, ShortcutsError>) -> Void)?
        controller.shortcutsClient.execute = { arguments, completion in requests.append(arguments); pending = completion }
        configureWheel([action], modes: [.onRelease]); selectSector(0)
        report(requests.isEmpty, "Workflow binding arms without running during selection")
        controller.close(cancel: false)
        report(requests == [shortcut.runArguments] && !controller.wheelVisible, "Release workflow invokes system identifier after closing wheel")
        controller.perform(action)
        report(requests.count == 1, "Running workflow cannot be duplicated by repeated entry")
        pending?(.success(""))
        later {
            self.report(controller.runningShortcuts.isEmpty && self.text.string == before, "Workflow completion clears running state without sending keys")
            self.configureWheel([action], modes: [.onEntry]); self.selectSector(0)
            self.report(requests.count == 2 && controller.wheel.feedback == .fired, "Entry workflow dispatches once and reports fired")
            controller.close(cancel: true); pending?(.success(""))
            self.configureWheel([action], modes: [.onRelease]); self.selectSector(0); controller.close(cancel: true)
            self.report(requests.count == 2, "Canceling pending workflow never dispatches it")
            self.later { self.verifyGestureAvailability() }
        }
    }
    // Capture keyboard events; exercise the actual Controller without desktop
    // injection or user preferences. Advancing time simulates sparse frames and
    // delayed main-run-loop servicing without spending minutes in the test.
    func verifyKeySequences(index: Int) {
        let heldActions = [56, 60, 59].map { code in
            KeyAction.find(RecordedKey.capture(key: UInt16(code), flags: []).storedValue)
        } + [KeyAction.find("space")]
        let finalActions = [KeyAction.find("return"), KeyAction.find("tab")]
        guard index < heldActions.count * finalActions.count else {
            print("PASS: \(checks) native key sequence checks (only own temporary window)"); fflush(stdout)
            NSApp.terminate(nil); return
        }
        let held = heldActions[index / finalActions.count], final = finalActions[index % finalActions.count]
        text.string = ""; window.makeFirstResponder(text); recorded.removeAll()
        sender.hold(held); sender.release(); sender.tap(final)
        later {
            let received = self.recorded.filter { $0.1 == Int64(final.key) }
            self.report(received.map { $0.0 } == [.keyDown, .keyUp], "Native held key \(held.key) -> final \(final.key) reaches session exactly once")
            let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            self.report(received.allSatisfy { CGEventFlags(rawValue: $0.2).intersection(modifierMask).isEmpty }, "Released key \(held.key) cannot contaminate final \(final.key) modifiers")
            self.report(self.text.string.hasSuffix(final.key == 36 ? "\n" : "\t"), "Native text responder handles final \(final.key) after immediate held-key release")
            self.verifyKeySequences(index: index + 1)
        }
    }
    func verifyIdleGestures() {
        let suite = "local.magicwheel.idle-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Settings(defaults: defaults)
        model.slots = ["space"]; model.hold = 0.30
        model.permission = true; model.hookReady = true
        var events: [CGEventType] = []
        let capture = KeySender(isTrusted: { true }, emit: { event, _ in events.append(event.type) })
        var focus = WheelFocusSnapshot(pid: getpid())
        var monitorRunning: Bool? = true
        let probe = Controller(settings: model, sender: capture, focusedApplication: { _ in focus }, deviceIsRunning: { _ in monitorRunning })
        probe.setupPanel()
        defer { probe.close(cancel: true) }
        let contacts = [Contact(id: 1, x: 0.3, y: 0.5), Contact(id: 2, x: 0.6, y: 0.5)]
        let selected = contacts.map { Contact(id: $0.id, x: $0.x, y: $0.y + 0.10) }
        for mode in TriggerMode.allCases {
            model.setTrigger(mode, at: 0)
            for remaining in [[], [contacts[0]]] {
                events.removeAll(); probe.core.reset(); probe.latest = nil; probe.configGuardUntil = 0
                probe.receive(device: 1, contacts: contacts)
                probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
                report(probe.wheelVisible && probe.core.active, "Idle \(mode.rawValue) gesture opens")
                probe.receive(device: 1, contacts: selected)
                let entry: [CGEventType] = mode == .onEntry ? [.keyDown, .keyUp] : mode == .whileInside ? [.keyDown] : []
                report(events == entry, "Idle \(mode.rawValue) commits immediately")
                probe.receive(device: 2, contacts: [])
                report(probe.latest?.0 == 1 && probe.wheelVisible && events == entry, "Another touch device cannot overwrite idle \(mode.rawValue) contacts")
                let start = ProcessInfo.processInfo.systemUptime
                for pause in [0.8, 1.2, 30, 600, 86_400, 604_800] {
                    probe.tick(time: start + pause)
                    report(probe.wheelVisible && probe.core.active && probe.candidate == 0 && events == entry,
                           "Idle \(mode.rawValue) survives \(pause)s without new touch frames or duplicate events")
                }
                probe.receive(device: 1, contacts: remaining)
                report(!probe.wheelVisible && events == [.keyDown, .keyUp], "Idle \(mode.rawValue) real lift completes one key pair")
                probe.close(cancel: false)
                report(events == [.keyDown, .keyUp], "Idle \(mode.rawValue) repeated close does not repeat")
                probe.receive(device: 1, contacts: [])
            }
        }
        model.slots = ["space", "tab"]
        model.setTrigger(.whileInside, at: 0); model.setTrigger(.onRelease, at: 1)
        probe.configGuardUntil = 0
        probe.receive(device: 1, contacts: contacts)
        probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
        events.removeAll(); probe.receive(device: 1, contacts: selected)
        probe.tick(time: ProcessInfo.processInfo.systemUptime + 600)
        probe.receive(device: 1, contacts: contacts)
        report(probe.wheelVisible && events == [.keyDown, .keyUp], "Leaving held sector after idle releases immediately and keeps wheel open")
        probe.receive(device: 1, contacts: selected)
        report(events == [.keyDown, .keyUp, .keyDown], "Reentering held sector immediately presses again")
        probe.receive(device: 1, contacts: contacts.map { Contact(id: $0.id, x: $0.x, y: $0.y - 0.10) })
        report(probe.candidate == 1 && events == [.keyDown, .keyUp, .keyDown, .keyUp], "Moving to release sector immediately releases held key without sending next action")
        probe.receive(device: 1, contacts: [])
        report(events == [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp], "Immediate lift after sector switch executes final action once")
        probe.core.reset(); probe.latest = nil; probe.configGuardUntil = 0
        probe.receive(device: 1, contacts: contacts)
        probe.tick(time: ProcessInfo.processInfo.systemUptime + 1)
        report(!probe.wheelVisible && probe.latest == nil, "Stale unconfirmed contact cannot start a new wheel")
        probe.receive(device: 1, contacts: [])
        model.slots = ["space", "tab"]
        model.setTrigger(.whileInside, at: 0); model.setTrigger(.onRelease, at: 1)
        for interruption in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            for interruptedWhileHolding in [true, false] {
                events.removeAll(); probe.core.reset(); probe.latest = nil; probe.configGuardUntil = 0
                probe.receive(device: 1, contacts: contacts)
                probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
                probe.receive(device: 1, contacts: selected)
                let releaseSector = contacts.map { Contact(id: $0.id, x: $0.x, y: $0.y - 0.10) }
                if !interruptedWhileHolding { probe.receive(device: 1, contacts: releaseSector) }
                let before = events
                probe.recoverEventTap(after: interruption)
                probe.recoverEventTap(after: interruption)
                report(probe.wheelVisible && probe.core.active && probe.settings.hookReady && events == before,
                       "Recovering event tap \(interruption.rawValue) preserves confirmed \(interruptedWhileHolding ? "hold" : "release selection") without duplicate events")
                if interruptedWhileHolding { probe.receive(device: 1, contacts: releaseSector) }
                report(probe.candidate == 1 && events == [.keyDown, .keyUp], "After tap recovery, leaving hold releases once and arms final action")
                probe.receive(device: 1, contacts: [])
                report(!probe.wheelVisible && events == [.keyDown, .keyUp, .keyDown, .keyUp], "Real finger lift after tap recovery sends final action exactly once")
            }
        }
        for canMonitor in [true, false] {
            events.removeAll(); probe.core.reset(); probe.latest = nil; probe.configGuardUntil = 0
            model.permission = true; model.hookReady = true
            probe.receive(device: 1, contacts: contacts)
            probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
            probe.receive(device: 1, contacts: selected)
            if canMonitor { model.permission = false } else { model.hookReady = false }
            probe.recoverEventTap(after: .tapDisabledByTimeout)
            report(probe.wheelVisible && probe.core.active && probe.actionsSuspended && events == [.keyDown, .keyUp], "Unrecoverable tap or revoked permission releases keys but preserves the wheel")
            probe.tick(time: ProcessInfo.processInfo.systemUptime + 604_800)
            probe.receive(device: 1, contacts: [])
            report(!probe.wheelVisible && !probe.core.active && events == [.keyDown, .keyUp], "Real lift closes even without permission or an event tap, without firing an action")
            model.permission = true; model.hookReady = true
        }
        for mode in [TriggerMode.whileInside, .onRelease] {
            model.slots = ["space"]; model.setTrigger(mode, at: 0)
            for cancellation in ["extra finger", "target switch", "disabled", "screen lock", "device monitor stopped", "device status unavailable"] {
                monitorRunning = true
                focus = WheelFocusSnapshot(pid: getpid()); model.enabled = true; probe.settingWasEnabled = true
                events.removeAll(); probe.configGuardUntil = 0
                probe.receive(device: 1, contacts: contacts)
                probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
                probe.receive(device: 1, contacts: selected)
                probe.tick(time: ProcessInfo.processInfo.systemUptime + 600)
                switch cancellation {
                case "extra finger": probe.receive(device: 1, contacts: selected + [Contact(id: 3, x: 0.8, y: 0.8)])
                case "target switch": focus = WheelFocusSnapshot(pid: -1); probe.frontmostChanged(); probe.tick()
                case "disabled": model.enabled = false; probe.tick()
                case "screen lock": probe.lockScreen()
                case "device monitor stopped": monitorRunning = false; probe.tick(time: ProcessInfo.processInfo.systemUptime + 601)
                default: monitorRunning = nil; probe.tick(time: ProcessInfo.processInfo.systemUptime + 601)
                }
                let interrupted = cancellation == "target switch" || cancellation == "device monitor stopped"
                let explicitExit = cancellation == "disabled" || cancellation == "screen lock"
                let entry: [CGEventType] = mode == .whileInside ? [.keyDown] : []
                let released: [CGEventType] = mode == .whileInside ? [.keyDown, .keyUp] : []
                report(probe.wheelVisible == !explicitExit && events == (interrupted || explicitExit ? released : entry),
                       "Idle \(mode.rawValue) \(cancellation) preserves visibility unless explicitly stopped")
                if !explicitExit {
                    focus = WheelFocusSnapshot(pid: getpid()); monitorRunning = true
                    probe.tick(time: ProcessInfo.processInfo.systemUptime + 604_800)
                    report(probe.wheelVisible && events == (interrupted ? released : entry), "Recovery never dismisses or replays an interrupted gesture")
                    probe.receive(device: 1, contacts: [])
                    report(!probe.wheelVisible && events == (interrupted ? released : [.keyDown, .keyUp]),
                           "Real lift finishes \(mode.rawValue) after \(cancellation) without a duplicate or invalid action")
                }
                probe.close(cancel: true); probe.core.reset(); probe.latest = nil
            }
        }
        model.enabled = true; model.permission = true; model.hookReady = true
        probe.settingWasEnabled = true; focus = WheelFocusSnapshot(pid: getpid())
        probe.showWheel(demo: true)
        events.removeAll()
        probe.tick(time: ProcessInfo.processInfo.systemUptime + 604_800)
        report(probe.wheelVisible && probe.demo && events.isEmpty, "Preview has no idle timeout, even after a week")
        probe.wheel.mouseClose?()
        report(!probe.wheelVisible, "Preview still closes on an explicit click")
        var keyboardRecipient = getpid()
        let actionProbe = Controller(settings: model, sender: capture, focusedApplication: { hint in
            WheelFocusSnapshot(pid: getpid(), keyboardPID: hint == nil ? keyboardRecipient : nil)
        }, deviceIsRunning: { _ in true })
        actionProbe.setupPanel()
        defer { actionProbe.close(cancel: true) }
        for final in ["return", "tab", "copy"] {
            keyboardRecipient = getpid(); model.enabled = true; model.permission = true; model.hookReady = true
            model.slots = ["space", final]
            model.setTrigger(.whileInside, at: 0); model.setTrigger(.onRelease, at: 1)
            actionProbe.showWheel(demo: false); events.removeAll()
            let angle = actionProbe.targetRotation
            actionProbe.move(WheelVector(x: sin(angle), y: cos(angle)))
            keyboardRecipient = -2
            actionProbe.move(WheelVector(x: -sin(angle), y: -cos(angle)))
            actionProbe.close(cancel: false)
            report(actionProbe.hasPendingAction && events == [.keyDown, .keyUp], "Active application alone cannot deliver \(final) while keyboard recipient differs")
            actionProbe.flushPendingActions()
            report(actionProbe.hasPendingAction && events == [.keyDown, .keyUp], "Repeated activation state cannot prematurely send \(final)")
            keyboardRecipient = getpid(); actionProbe.flushPendingActions()
            report(!actionProbe.hasPendingAction && events == [.keyDown, .keyUp, .keyDown, .keyUp], "Actual input target restoration sends \(final) once without an activation change")
            actionProbe.flushPendingActions()
            report(events == [.keyDown, .keyUp, .keyDown, .keyUp], "Actual recipient restoration cannot duplicate \(final)")
        }
    }
    func verifyGestureAvailability() {
        let suite = "local.magicwheel.focus-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = Settings(defaults: defaults)
        model.slots = [""]; model.hold = 0.30; model.enabled = true
        model.permission = AXIsProcessTrusted(); model.hookReady = true; model.deviceCount = 1
        let probe = Controller(settings: model); probe.setupPanel(); probe.showSettings()
        probe.setupMenu()
        report(probe.statusItem.menu?.items.map(\.title) == ["禁用轮盘", "打开设置", "开机启动", "退出应用"], "Status menu contains exactly four requested actions")
        let originalMenu = probe.statusItem.menu
        probe.toggleEnabled()
        report(!model.enabled && probe.statusItem.menu?.item(withTag: 1)?.state == .on, "Disable item checks when gestures are disabled")
        probe.toggleEnabled()
        report(model.enabled && probe.statusItem.menu?.item(withTag: 1)?.state == .off && probe.statusItem.menu === originalMenu, "Re-enabling clears check without rebuilding open menu")
        let contacts = [Contact(id: 1, x: 0.3, y: 0.5), Contact(id: 2, x: 0.6, y: 0.5)]
        func arm() {
            probe.configGuardUntil = 0
            probe.receive(device: 1, contacts: contacts)
            probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
        }
        let ownID = Bundle.main.bundleIdentifier ?? "local.magicwheel.app"
        _ = model.addApplication(id: ownID, name: "Integration host", path: "")
        model.slots = ["", ""]
        model.rotation = 0.7
        model.selectApplication(nil)
        arm()
        report(probe.wheelVisible, "Gesture opens while its own settings are frontmost")
        report(probe.targetActions.count == 2 && probe.targetRotation == 0.7, "Runtime matches focused application even while editor is global")
        let frozenActions = probe.targetActions.map(\.id)
        model.selectApplication(ownID); model.slots = ["", "", ""]
        report(probe.targetActions.map(\.id) == frozenActions, "Open gesture freezes profile despite editor changes")
        for (down, up) in [(CGEventType.rightMouseDown, CGEventType.rightMouseUp), (.leftMouseDown, .leftMouseUp), (.otherMouseDown, .otherMouseUp)] {
            report(probe.handlePointerButton(down), "Open wheel swallows mouse-down without passing a stray click")
            probe.blockPendingForPointerClick()
            probe.receive(device: 1, contacts: contacts)
            report(probe.wheelVisible && probe.core.active, "Pressure click and continued contact preserve the active wheel")
            report(probe.handlePointerButton(up), "Open wheel balances suppressed mouse-up")
            report(!probe.handlePointerButton(up), "Mouse-up suppression is consumed exactly once")
        }
        report(probe.handlePointerButton(.rightMouseDown), "Right click is suppressed before release")
        probe.receive(device: 1, contacts: [contacts[0]])
        report(!probe.wheelVisible, "Actual finger release still closes after a pressure click")
        report(probe.handlePointerButton(.rightMouseUp), "Mouse-up after wheel closes remains paired with swallowed down")
        probe.receive(device: 1, contacts: []); probe.configGuardUntil = 0
        report(!probe.handlePointerButton(.rightMouseDown), "Ordinary right click without a hold passes through")
        report(!probe.handlePointerButton(.rightMouseUp), "Ordinary right release passes through")
        arm()
        report(probe.wheelVisible, "Idle right click does not poison the next independent hold")
        probe.close(cancel: true); probe.core.reset(); probe.configGuardUntil = 0
        probe.receive(device: 1, contacts: contacts)
        report(!probe.handlePointerButton(.rightMouseDown), "Right click during arming remains ordinary system input")
        probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
        report(!probe.wheelVisible, "Right click prevents a pending hold from opening")
        report(!probe.handlePointerButton(.rightMouseUp), "Pending hold preserves the ordinary right-button pair")
        probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.5)
        report(!probe.wheelVisible, "Releasing the mouse button alone cannot rearm while fingers remain")
        probe.receive(device: 1, contacts: []); arm()
        report(probe.wheelVisible, "Full finger lift allows a new hold after right click")
        probe.close(cancel: true); probe.core.reset(); probe.settingsWindow.performClose(nil)
        arm()
        report(probe.wheelVisible && !probe.settingsWindow.isVisible, "Closed settings cannot suppress global gesture")
        probe.receive(device: 1, contacts: [contacts[0]])
        report(!probe.wheelVisible, "Lifting one finger ends the gesture before cooldown")
        probe.receive(device: 1, contacts: [])
        probe.receive(device: 1, contacts: contacts)
        let deadline = probe.configGuardUntil
        probe.tick(time: deadline + 0.01); probe.tick(time: deadline + 0.32)
        report(probe.wheelVisible, "Lift during cooldown resets gesture even when next contact arrives immediately")
        probe.close(cancel: true); probe.core.reset(); probe.configGuardUntil = 0
        probe.receive(device: 1, contacts: contacts)
        probe.receive(device: 1, contacts: contacts.map { Contact(id: $0.id, x: $0.x + 0.04, y: $0.y) })
        probe.receive(device: 1, contacts: [])
        probe.receive(device: 1, contacts: contacts)
        probe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
        report(probe.wheelVisible, "All-up frame between timer ticks clears a canceled scroll candidate")
        probe.targetPID = -1; probe.tick()
        report(probe.wheelVisible && probe.actionsSuspended, "Target switch retains old gesture while suspending its actions")
        probe.receive(device: 1, contacts: [])
        report(!probe.wheelVisible, "Real lift closes after target focus changes")
        arm()
        report(probe.wheelVisible, "Fresh hold can open after target focus changes")
        probe.close(cancel: true); probe.settingsWindow.orderOut(nil)
        probe.updateMonitoringActivity()
        report(probe.monitoringActivity != nil, "Enabled global monitor retains background activity")
        model.enabled = false; probe.updateMonitoringActivity()
        report(probe.monitoringActivity == nil, "Pausing releases background activity")
        var trackingTicks = 0
        let trackingTimer = Controller.commonTimer(interval: 0.005) { trackingTicks += 1 }
        // Allow the first SwiftUI profile redraw to finish before judging a timer;
        // this checks run-loop mode membership, not a 30 ms rendering deadline.
        let until = Date().addingTimeInterval(1)
        while trackingTicks == 0 && Date() < until { RunLoop.current.run(mode: .eventTracking, before: until) }
        trackingTimer.invalidate()
        report(trackingTicks > 0, "Gesture timer runs in AppKit event-tracking mode")
        // Exercise real contact-frame -> selection -> close -> key encoding,
        // capturing events rather than injecting anything into the desktop.
        let quickSuite = "local.magicwheel.quick-exit." + UUID().uuidString
        let quickDefaults = UserDefaults(suiteName: quickSuite)!
        let quickModel = Settings(defaults: quickDefaults)
        quickModel.slots = ["space"]; quickModel.hold = 0.30
        quickModel.permission = true; quickModel.hookReady = true
        var quickEvents: [CGEventType] = []
        var quickKeyCodes: [Int64] = []
        let quickSender = KeySender(isTrusted: { true }, emit: { event, _ in
            quickEvents.append(event.type); quickKeyCodes.append(event.getIntegerValueField(.keyboardEventKeycode))
        })
        let targetFocus = WheelFocusSnapshot(pid: getpid())
        var simulatedFocus: WheelFocusSnapshot? = targetFocus
        let quickProbe = Controller(settings: quickModel, sender: quickSender, focusedApplication: { _ in simulatedFocus }); quickProbe.setupPanel()
        let recoveryTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
        report(recoveryTap != nil, "Native passive event tap can be created for recovery check")
        if let recoveryTap {
            let recoverySource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, recoveryTap, 0)!
            CFRunLoopAddSource(CFRunLoopGetMain(), recoverySource, .commonModes)
            quickProbe.eventTap = recoveryTap; CGEvent.tapEnable(tap: recoveryTap, enable: false)
            quickModel.hookReady = false; quickProbe.recoverEventTap(after: .tapDisabledByTimeout)
            report(quickModel.hookReady && CGEvent.tapIsEnabled(tap: recoveryTap), "Real disabled event tap reenables immediately without a fixed delay")
            quickProbe.eventTap = nil
            CFRunLoopRemoveSource(CFRunLoopGetMain(), recoverySource, .commonModes); CFMachPortInvalidate(recoveryTap)
        }
        for mode in TriggerMode.allCases {
            quickModel.setTrigger(mode, at: 0)
            for remaining in [[], [contacts[0]]] {
                quickProbe.configGuardUntil = 0
                quickProbe.receive(device: 1, contacts: contacts)
                quickProbe.tick(time: ProcessInfo.processInfo.systemUptime + 0.31)
                report(quickProbe.wheelVisible, "Quick \(mode.rawValue) gesture opens")
                quickEvents.removeAll()
                quickProbe.receive(device: 1, contacts: contacts.map { Contact(id: $0.id, x: $0.x, y: $0.y + 0.10) })
                let entryEvents: [CGEventType] = mode == .onEntry ? [.keyDown, .keyUp] : mode == .whileInside ? [.keyDown] : []
                report(quickProbe.candidate == 0 && quickProbe.committed == 0 && quickEvents == entryEvents, "\(mode.rawValue) selection commits in the same contact frame without waiting")
                quickProbe.receive(device: 1, contacts: contacts.map { Contact(id: $0.id, x: $0.x, y: $0.y + 0.10) })
                report(quickEvents == entryEvents, "Remaining in a sector cannot repeat the immediate action")
                quickProbe.receive(device: 1, contacts: remaining)
                report(!quickProbe.wheelVisible && quickEvents == [.keyDown, .keyUp], "Quick \(mode.rawValue) lift sends exactly one balanced key pair")
                quickProbe.close(cancel: false)
                report(quickEvents == [.keyDown, .keyUp], "Repeated quick close cannot duplicate key")
                quickProbe.receive(device: 1, contacts: [])
            }
        }
        let keyboardPID = InputActions.keyboardFocusPID()
        report(keyboardPID.flatMap { NSRunningApplication(processIdentifier: $0) } != nil, "System accessibility query identifies a running keyboard application")
        for preceding in ["control", "space"] {
            for following in ["return", "tab", "copy"] {
                let heldAction = KeyAction.find(preceding), finalAction = KeyAction.find(following)
                quickModel.slots = [preceding, following]
                quickModel.setTrigger(.whileInside, at: 0); quickModel.setTrigger(.onRelease, at: 1)
                let initialEvent: CGEventType = heldAction.held ? .flagsChanged : .keyDown
                let releaseEvent: CGEventType = heldAction.held ? .flagsChanged : .keyUp
                let releasedCodes = [Int64(heldAction.key), Int64(heldAction.key)]
                let finalCodes = releasedCodes + [Int64(finalAction.key), Int64(finalAction.key)]
                func auxiliaryThenSelection() {
                    simulatedFocus = targetFocus
                    quickProbe.showWheel(demo: false)
                    quickEvents.removeAll(); quickKeyCodes.removeAll()
                    let angle = quickProbe.targetRotation
                    quickProbe.move(WheelVector(x: sin(angle), y: cos(angle)))
                    report(quickEvents == [initialEvent] && quickKeyCodes == [Int64(heldAction.key)], "\(preceding) holds immediately")
                    simulatedFocus = WheelFocusSnapshot(pid: -2, isAuxiliary: true)
                    quickProbe.frontmostChanged()
                    report(quickProbe.wheelVisible, "Generic auxiliary activation preserves an established wheel")
                    quickProbe.move(WheelVector(x: -sin(angle), y: -cos(angle)))
                    report(quickProbe.wheelVisible && quickProbe.wheel.feedback == .releaseReady && quickKeyCodes == releasedCodes, "Held key releases before \(following) is armed")
                }
                auxiliaryThenSelection()
                quickProbe.close(cancel: false)
                report(!quickProbe.wheelVisible && quickProbe.hasPendingAction && quickKeyCodes == releasedCodes, "Fast exit retains \(following) during transient focus")
                quickProbe.close(cancel: false)
                simulatedFocus = targetFocus; quickProbe.frontmostChanged()
                report(!quickProbe.hasPendingAction && quickKeyCodes == finalCodes && quickEvents == [initialEvent,releaseEvent,.keyDown,.keyUp], "Original focus receives \(following) exactly once after release")
                quickProbe.frontmostChanged(); quickProbe.tick()
                report(quickKeyCodes == finalCodes, "Repeated notifications cannot duplicate an action")
                auxiliaryThenSelection()
                quickProbe.close(cancel: false)
                simulatedFocus = WheelFocusSnapshot(pid: -3); quickProbe.frontmostChanged()
                simulatedFocus = targetFocus; quickProbe.frontmostChanged()
                report(!quickProbe.hasPendingAction && quickKeyCodes == releasedCodes, "Switching regular applications cancels a pending action")
                auxiliaryThenSelection()
                quickProbe.close(cancel: true)
                simulatedFocus = targetFocus; quickProbe.frontmostChanged()
                report(!quickProbe.hasPendingAction && quickKeyCodes == releasedCodes, "Explicit cancellation never sends an armed action")
                auxiliaryThenSelection()
                simulatedFocus = targetFocus
                quickProbe.close(cancel: false)
                report(!quickProbe.hasPendingAction && quickKeyCodes == finalCodes, "Restored target receives action immediately without a fixed delay")
                auxiliaryThenSelection()
                quickProbe.close(cancel: false)
                quickProbe.flushPendingActions(time: ProcessInfo.processInfo.systemUptime + 2)
                simulatedFocus = targetFocus; quickProbe.frontmostChanged()
                report(!quickProbe.hasPendingAction && quickKeyCodes == releasedCodes, "Expired focus transition cannot send a stale action")
                auxiliaryThenSelection()
                quickProbe.close(cancel: false)
                quickModel.permission = false
                simulatedFocus = targetFocus; quickProbe.frontmostChanged()
                report(!quickProbe.hasPendingAction && quickKeyCodes == releasedCodes, "Permission loss cancels pending actions")
                quickModel.permission = true
            }
        }
        quickModel.slots = ["return"]; quickModel.setTrigger(.onRelease, at: 0)
        simulatedFocus = targetFocus; quickProbe.showWheel(demo: false)
        quickEvents.removeAll(); quickKeyCodes.removeAll()
        simulatedFocus = WheelFocusSnapshot(pid: -4, isAuxiliary: true)
        let singleAngle = quickProbe.targetRotation
        quickProbe.move(WheelVector(x: sin(singleAngle), y: cos(singleAngle)))
        quickProbe.close(cancel: false)
        report(quickProbe.hasPendingAction && quickEvents.isEmpty, "Generic focus transition retains an action without any preceding held key")
        simulatedFocus = targetFocus; quickProbe.frontmostChanged()
        report(!quickProbe.hasPendingAction && quickKeyCodes == [36,36], "Generic focus restoration works without any modifier or voice interaction")
        quickModel.slots = ["space", "return"]
        quickModel.setTrigger(.whileInside, at: 0); quickModel.setTrigger(.onRelease, at: 1)
        simulatedFocus = targetFocus; quickProbe.showWheel(demo: false)
        quickEvents.removeAll(); quickKeyCodes.removeAll()
        simulatedFocus = WheelFocusSnapshot(pid: -2, isAuxiliary: true)
        let heldAngle = quickProbe.targetRotation
        quickProbe.move(WheelVector(x: sin(heldAngle), y: cos(heldAngle)))
        report(quickEvents.isEmpty, "A hold is not sent to a transient auxiliary recipient")
        simulatedFocus = targetFocus; quickProbe.flushPendingActions()
        report(quickEvents == [.keyDown], "A still-selected hold begins when its input target returns")
        quickProbe.move(WheelVector()); quickProbe.close(cancel: false)
        report(quickEvents == [.keyDown,.keyUp], "Restored held action releases exactly once on exit")
        simulatedFocus = targetFocus; quickProbe.showWheel(demo: false)
        quickEvents.removeAll(); quickKeyCodes.removeAll()
        simulatedFocus = WheelFocusSnapshot(pid: -2, isAuxiliary: true)
        quickProbe.move(WheelVector(x: sin(heldAngle), y: cos(heldAngle)))
        quickProbe.move(WheelVector()); quickProbe.close(cancel: false)
        simulatedFocus = targetFocus; quickProbe.flushPendingActions()
        report(quickEvents.isEmpty, "Leaving a held sector during transient focus cancels its deferred key-down")
        quickDefaults.removePersistentDomain(forName: quickSuite)
        verifyIdleGestures()
        model.enabled = true; probe.settingWasEnabled = true; probe.core.reset()
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.report(NSApp.isHidden && front != getpid(), "Availability check runs with another application focused")
            arm()
            self.report(probe.targetActions.count == 1, "Unconfigured foreground application falls back to global despite app editor selection")
            probe.close(cancel: true); probe.core.reset()
            if let frontApp = NSWorkspace.shared.frontmostApplication, let frontID = frontApp.bundleIdentifier {
                _ = model.addApplication(id: frontID, name: frontApp.localizedName ?? frontID, path: frontApp.bundleURL?.path ?? "")
                model.slots = ["", "", "", ""]
                model.rotation = 1.1
                model.selectApplication(ownID)
                arm()
                self.report(probe.targetActions.count == 4 && probe.targetRotation == 1.1, "Second actual foreground application uses its own independent wheel")
            } else { arm() }
            self.report(probe.wheelVisible && probe.panel.isVisible, "Hidden background application can display the wheel")
            self.report(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "Opening background wheel preserves target application focus")
            probe.close(cancel: true)
            defaults.removePersistentDomain(forName: suite)
            NSApp.unhideWithoutActivation()
            self.window.makeKeyAndOrderFront(nil); self.window.makeFirstResponder(self.text)
            NSApp.activate(ignoringOtherApps: true)
            if CommandLine.arguments.contains("--gesture-test") {
                print("PASS: \(self.checks) gesture lifecycle checks (no key injection)"); fflush(stdout)
                NSApp.terminate(nil)
            } else { self.later { self.verifyOption() } }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { sender.release(); wheelController?.close(cancel: true) }

}
// No key injection: exercises real background cursor visibility and panel lifecycle.
final class CursorReviewDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller!
    let suite = "local.magicwheel.cursor-review"
    var checks = 0
    func check(_ result: Bool, _ name: String) {
        checks += 1
        print("\(result ? "PASS" : "FAIL"): \(name)"); fflush(stdout)
        if !result { controller?.close(cancel: true); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); exit(1) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = Settings(defaults: defaults); settings.slots = ["return", "copy", "paste", "escape"]
        controller = Controller(settings: settings); controller.setupPanel()
        controller.heartbeat = Controller.commonTimer(interval: 1 / 60) { [weak self] in self?.controller.tick() }
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.run(index: 0) }
    }
    func run(index: Int) {
        guard index < WheelTheme.allCases.count else {
            controller.close(cancel: true); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            print("PASS: \(checks) background cursor/panel checks"); fflush(stdout); NSApp.terminate(nil); return
        }
        let theme = WheelTheme.allCases[index]
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let position = NSEvent.mouseLocation
        check(target != getpid(), "\(theme.rawValue): test starts with another app focused")
        let initialVisibility = WheelCursor.systemVisible
        print("Cursor baseline: \(String(describing: initialVisibility))"); fflush(stdout)
        check(initialVisibility != nil, "\(theme.rawValue): actual cursor visibility is observable")
        controller.settings.theme = theme
        controller.showWheel(demo: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.check(self.controller.backgroundCursorEnabled, "\(theme.rawValue): background cursor connection enabled")
            self.check(self.controller.panel.isVisible, "\(theme.rawValue): nonactivating panel is visible")
            self.check(self.controller.cursorHidden && WheelCursor.systemVisible == false, "\(theme.rawValue): real cursor is invisible while backgrounded")
            self.check(NSWorkspace.shared.frontmostApplication?.processIdentifier == target, "\(theme.rawValue): target app retains focus")
            self.check(NSEvent.mouseLocation == position, "\(theme.rawValue): pointer was not moved")
            self.controller.close(cancel: true); self.controller.close(cancel: true)
            self.check(WheelCursor.systemVisible == initialVisibility && self.controller.cursorRestoreSucceeded, "\(theme.rawValue): cancel and repeated close restore prior cursor visibility")
            self.run(index: index + 1)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.close(cancel: true) }
}

final class GlassReviewBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSGradient(starting: NSColor(white: dark ? 0.12 : 0.95, alpha: 1), ending: NSColor(white: dark ? 0.35 : 0.65, alpha: 1))?.draw(in: bounds, angle: -30)
        for n in 0..<18 {
            let p = NSBezierPath(); p.move(to: NSPoint(x: CGFloat(n) * 80 - 320, y: 0))
            p.curve(to: NSPoint(x: CGFloat(n) * 80 + 120, y: bounds.height), controlPoint1: NSPoint(x: CGFloat(n) * 80 + 110, y: bounds.height * 0.4), controlPoint2: NSPoint(x: CGFloat(n) * 80 - 160, y: bounds.height * 0.6))
            NSColor(white: dark ? 0.85 : 0.15, alpha: 0.18).setStroke(); p.lineWidth = 6; p.stroke()
        }
    }
}
final class GlassReviewDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var timer: Timer?
    var wheels: [WheelView] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let themeReview = CommandLine.arguments.contains("--theme-review")
        let width = CGFloat(themeReview ? WheelTheme.allCases.count : 3) * 340 + 20
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = themeReview ? "Orvia · 主题预览（移动鼠标预览）" : "Orvia · Liquid Glass 材质验证"
        window.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        let backdrop = GlassReviewBackdrop(frame: NSRect(x: 0, y: 0, width: width, height: 460)); window.contentView = backdrop
        let phases: [WheelFeedback] = themeReview ? WheelTheme.allCases.map { _ in .releaseReady } : [.holding, .releaseReady, .fired]
        for (n, phase) in phases.enumerated() {
            let wheel = WheelView()
            wheel.actions = [KeyAction.find("option"), KeyAction.find("return"), KeyAction.find("settings"), KeyAction.find("spotlight")]
            wheel.triggerModes = [.whileInside, .onEntry, .onRelease, .onEntry]
            if themeReview {
                wheel.theme = WheelTheme.allCases[n]
                wheel.demonstration = true
                wheel.mouseMove = { [weak wheel] vector in
                    guard let wheel else { return }
                    wheel.vector = vector
                    wheel.selected = vector.length > 0.35 ? wheelSector(vector, count: wheel.actions.count, rotation: wheel.rotation) : nil
                    wheel.feedback = wheel.selected == nil ? .idle : .releaseReady
                }
            }
            wheel.selected = [0, 2, 1, 1][n]; wheel.feedback = phase
            wheel.vector = [WheelVector(x: 0,y: 0.6), WheelVector(x: 0,y: -0.6), WheelVector(x: 0.6,y: 0), WheelVector(x: 0.6,y: 0)][n]
            let surface = WheelSurface(wheel: wheel, frame: NSRect(x: 20 + n * 340, y: 80, width: 320, height: 320))
            surface.withinWindow(); backdrop.addSubview(surface); wheels.append(wheel)
            let title = NSTextField(labelWithString: themeReview ? WheelTheme.allCases[n].title + " · " + WheelTheme.allCases[n].detail : ["持续按下 · 呼吸", "松手执行 · 双层边缘", "移入触发 · 扩散波纹"][n])
            title.frame = NSRect(x: 20 + n * 340, y: 30, width: 320, height: 25); title.alignment = .center; backdrop.addSubview(title)
        }
        var lastReviewStep = -1
        timer = Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { [weak self] _ in
            guard let self else { return }; let now = ProcessInfo.processInfo.systemUptime
            for wheel in self.wheels { wheel.animationTime = now }
            if themeReview, CommandLine.arguments.contains("--animate") {
                let step = Int(now / 1.5)
                if step != lastReviewStep {
                    lastReviewStep = step
                    for wheel in self.wheels {
                        let index = step % wheel.actions.count
                        wheel.selected = index; wheel.feedback = .releaseReady
                        let a = Double(index) * 2 * .pi / Double(wheel.actions.count)
                        wheel.vector = WheelVector(x: sin(a) * 0.8, y: cos(a) * 0.8)
                    }
                }
            }
            // Repeat the one-shot state only in this review window.
            if Int(now * 60) % 150 == 0, let last = self.wheels.last { last.feedback = .idle; last.feedback = .fired }
        }
        window.acceptsMouseMovedEvents = true
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
var appController: Controller?
let app = NSApplication.shared
// Developer-only rendering of the same live-wheel drawing code.
if let argument = CommandLine.arguments.firstIndex(of: "--render-feedback"), CommandLine.arguments.indices.contains(argument + 1) {
    let directory = URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, index, phase) in [("holding", 0, WheelFeedback.holding), ("release", 2, .releaseReady), ("entry", 1, .fired)] {
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        view.actions = [KeyAction.find("option"), KeyAction.find("return"), KeyAction.find("settings"), KeyAction.find("spotlight")]
        view.triggerModes = [.whileInside, .onEntry, .onRelease, .onEntry]
        view.selected = index; view.vector = WheelVector(x: index == 1 ? 1 : 0, y: index == 0 ? 1 : index == 2 ? -1 : 0)
        view.animationTime = 100; view.feedback = phase; view.animationTime = 100.5
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: 2); transform.concat()
        NSColor.controlBackgroundColor.setFill(); view.bounds.fill(); view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
    exit(0)
}
// Standard responder menus also make Command shortcuts work in native controls.
let mainMenu = NSMenu()
let applicationMenu = NSMenu()
let applicationItem = NSMenuItem(); applicationItem.submenu = applicationMenu
applicationMenu.addItem(withTitle: "退出 Orvia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
mainMenu.addItem(applicationItem)
let edit = NSMenu(title: "编辑")
for (title, selector, key) in [("撤销", NSSelectorFromString("undo:"), "z"),
                              ("复制", #selector(NSText.copy(_:)), "c"),
                              ("粘贴", #selector(NSText.paste(_:)), "v"),
                              ("全选", #selector(NSText.selectAll(_:)), "a")] {
    edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
}
let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit
mainMenu.addItem(editItem); app.mainMenu = mainMenu
let delegate: NSObject & NSApplicationDelegate
if CommandLine.arguments.contains("--cursor-test") {
    delegate = CursorReviewDelegate()
} else if CommandLine.arguments.contains("--glass-review") || CommandLine.arguments.contains("--theme-review") {
    delegate = GlassReviewDelegate()
} else if CommandLine.arguments.contains("--key-sequence-test") || CommandLine.arguments.contains("--text-editor-test") || CommandLine.arguments.contains("--quick-text-send-test") || CommandLine.arguments.contains("--idle-gesture-test") || CommandLine.arguments.contains("--scene-test") || CommandLine.arguments.contains("--gesture-test") || CommandLine.arguments.contains("--shortcut-test") || CommandLine.arguments.contains("--input-actions-test") || CommandLine.arguments.contains("--integration-test") || CommandLine.arguments.contains("--voice-test") || CommandLine.arguments.contains("--login-item-test") {
    delegate = IntegrationDelegate()
} else {
    let settings: Settings
    if CommandLine.arguments.contains("--settings-review") {
        let reviewDefaults = UserDefaults(suiteName: "local.magicwheel.settings-review")!
        reviewDefaults.removePersistentDomain(forName: "local.magicwheel.settings-review")
        for (key, value) in UserDefaults.standard.persistentDomain(forName: "local.magicwheel.app") ?? [:] { reviewDefaults.set(value, forKey: key) }
        settings = Settings(defaults: reviewDefaults)
        if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
    } else { settings = Settings() }
    let controller = Controller(settings: settings); appController = controller; delegate = controller
}
app.delegate = delegate
app.run()
