import AppKit
import ServiceManagement
import UniformTypeIdentifiers

extension Controller {
    private var launchAtLoginConfigured: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }
    private func transferError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = settings.l("无法完成设置传输")
        alert.informativeText = (error as? SettingsFile.FileError).map { settings.l($0.message) } ?? error.localizedDescription
        alert.addButton(withTitle: settings.l("好")); alert.runModal()
    }
    func exportSettings() {
        KeyRecorderButton.active?.stop()
        let panel = NSSavePanel()
        panel.title = settings.l("导出全部设置")
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Orvia-settings.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SettingsFile(settings: settings, launchAtLogin: launchAtLoginConfigured).encoded().write(to: url, options: .atomic) }
        catch { transferError(error) }
    }
    @discardableResult
    func importSettings() -> Bool {
        KeyRecorderButton.active?.stop()
        let panel = NSOpenPanel()
        panel.title = settings.l("导入设置")
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let file = try SettingsFile.read(from: url)
            let apps = file.applicationGroups.reduce(0) { $0 + $1.applications.count }
            let alert = NSAlert(); alert.messageText = settings.l("导入并替换全部设置？")
            let summary = settings.language == .chinese
                ? "全局轮盘：\(file.global.slots.count) 个键位\n命名场景：\(file.applicationGroups.count) 个，\(apps) 项应用条件\n旧文本输入配置：\(file.scenes.count) 个"
                : "Global wheel: \(file.global.slots.count) slots\nNamed scenes: \(file.applicationGroups.count), \(apps) app conditions\nLegacy text profiles: \(file.scenes.count)"
            alert.informativeText = url.lastPathComponent + "\n\n" + summary + "\n\n" + settings.l("当前全部设置会先自动备份，再替换为文件中的设置。")
                + "\n" + settings.l("系统权限和快捷指令本体不会随文件迁移。")
            let login = NSButton(checkboxWithTitle: settings.l("同时应用文件中的开机启动设置"), target: nil, action: nil)
            login.state = .on
            login.title += file.preferences.launchAtLogin ? " · " + settings.l("开启") : " · " + settings.l("关闭")
            login.sizeToFit(); alert.accessoryView = login
            alert.addButton(withTitle: settings.l("导入并替换")); alert.addButton(withTitle: settings.l("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            let review = CommandLine.arguments.contains("--settings-review")
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent(review ? "MagicWheel/ReviewBackups" : "MagicWheel/Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = directory.appendingPathComponent("MagicWheel-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            try SettingsFile(settings: settings, launchAtLogin: launchAtLoginConfigured).encoded().write(to: backup, options: .atomic)
            if login.state == .on && !review && file.preferences.launchAtLogin != launchAtLoginConfigured {
                if file.preferences.launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            }
            close(cancel: true); core.reset(); latest = nil
            try settings.applyImport(file)
            updateMonitoringActivity(); refreshMenu()
            let done = NSAlert(); done.messageText = settings.l("设置已导入")
            done.informativeText = settings.l("原设置已备份，可通过“导入设置”恢复：") + "\n" + backup.path
            if !review && file.preferences.launchAtLogin && SMAppService.mainApp.status == .requiresApproval {
                done.informativeText += "\n\n" + settings.l("开机启动正在等待系统批准，请在系统设置的登录项中开启。")
            }
            done.addButton(withTitle: settings.l("好")); done.addButton(withTitle: settings.l("显示备份"))
            if done.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
            return true
        } catch { transferError(error); return false }
    }
}
