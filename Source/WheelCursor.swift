import AppKit
import Darwin

/// Owns one balanced cursor-hide request. A successful CG call alone does not
/// prove that the cursor disappeared when this nonactivating app is backgrounded.
final class WheelCursor {
    struct Backend {
        var allowBackground: (Bool) -> Bool
        var hide: () -> Bool
        var show: () -> Bool
        var visible: () -> Bool
        static let system = Backend(
            allowBackground: BackgroundCursorConnection.setEnabled,
            hide: { CGDisplayHideCursor(CGMainDisplayID()) == .success },
            show: { CGDisplayShowCursor(CGMainDisplayID()) == .success },
            visible: { WheelCursor.systemVisible ?? true }
        )
    }
    // Deprecated in Swift, still exported by WindowServer on supported macOS.
    // Optional lookup keeps visibility failures distinct from hide success.
    private typealias VisibilityQuery = @convention(c) () -> UInt32
    private static let visibilityQuery: VisibilityQuery? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(symbol, to: VisibilityQuery.self)
    }()
    static var systemVisible: Bool? { visibilityQuery.map { $0() != 0 } }
    var supportsBackgroundHiding: Bool { backgroundEnabled }
    private let backend: Backend
    private(set) var ownsHide = false
    private(set) var restoreSucceeded = true
    private var backgroundEnabled = false
    private var lastCheck = -Double.greatestFiniteMagnitude
    var hidden: Bool { ownsHide && !backend.visible() }
    init(backend: Backend = .system) { self.backend = backend }
    @discardableResult func begin() -> Bool {
        if ownsHide { return hidden }
        backgroundEnabled = backend.allowBackground(true) || backgroundEnabled
        ownsHide = backend.hide()
        restoreSucceeded = !ownsHide
        if !ownsHide, backgroundEnabled { _ = backend.allowBackground(false); backgroundEnabled = false }
        return hidden
    }
    func maintain(time: Double) {
        guard ownsHide, time - lastCheck >= 0.1 else { return }
        lastCheck = time
        guard backend.visible() else { return }
        // WindowServer can reset visibility on a display/focus update. Balance
        // the old request before reissuing it; never accumulate hide counts.
        guard backend.show() else { return }
        ownsHide = false
        _ = begin()
    }
    func end() {
        if ownsHide {
            restoreSucceeded = backend.show()
            if restoreSucceeded { ownsHide = false }
        }
        if !ownsHide, backgroundEnabled {
            _ = backend.allowBackground(false); backgroundEnabled = false
        }
    }
    deinit { end() }
}

/// Optional WindowServer compatibility shim. The public hide API is normally
/// foreground-only. This private, runtime-resolved property affects only our
/// own connection and never activates an app or changes another app's cursor.
/// If removed by macOS, missing symbols fail closed without an unsafe call.
private enum BackgroundCursorConnection {
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static let handle = dlopen(nil, RTLD_LAZY)
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let handle,
              let connectionSymbol = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
              let propertySymbol = dlsym(handle, "CGSSetConnectionProperty") else { return false }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        guard connection != 0 else { return false }
        let set = unsafeBitCast(propertySymbol, to: SetProperty.self)
        return set(connection, connection, "SetsCursorInBackground" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse) == 0
    }
}
