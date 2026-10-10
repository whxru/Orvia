import CoreGraphics
import Foundation
import ApplicationServices
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func pair(_ dx: Double = 0, _ dy: Double = 0) -> [Contact] {
    [Contact(id: 1, x: 0.3 + dx, y: 0.5 + dy), Contact(id: 2, x: 0.6 + dx, y: 0.5 + dy)]
}
let g = GestureCore()
check(g.consume(device: 1, contacts: pair(), time: 0).isEmpty, "arming does not open immediately")
check(g.consume(device: 1, contacts: pair(), time: 0.44).isEmpty, "hold threshold")
check(g.consume(device: 2, contacts: pair(), time: 0.6).isEmpty, "another device must not complete hold")
check(g.consume(device: 1, contacts: pair(), time: 0.46) == [.show, .move(WheelVector())], "stationary two-finger hold opens")
let moved = g.consume(device: 1, contacts: pair(0, 0.14), time: 0.5)
if case .move(let v) = moved.first { check(abs(v.y - 1) < 1e-8, "normalized directional travel") } else { check(false, "movement effect") }
check(g.consume(device: 1, contacts: [pair()[0]], time: 0.6) == [.finish], "lifting one finger releases hold")
check(g.consume(device: 1, contacts: pair(), time: 2).isEmpty, "must lift both before another gesture")
_ = g.consume(device: 1, contacts: [], time: 2.1)
check(g.consume(device: 1, contacts: pair(), time: 3).isEmpty, "new gesture may arm")
check(g.consume(device: 1, contacts: pair(0.025), time: 3.1).isEmpty, "scroll moves cancel arming")
check(g.consume(device: 1, contacts: pair(0.025), time: 4).isEmpty, "scroll cannot open later")
g.reset()
_ = g.consume(device: 1, contacts: pair(), time: 0)
_ = g.consume(device: 1, contacts: pair(), time: 1)
check(g.consume(device: 1, contacts: pair() + [Contact(id: 3, x: 0.8, y: 0.5)], time: 1.1) == [.move(WheelVector())], "third finger preserves wheel and original centroid")
check(g.consume(device: 1, contacts: pair(), time: 604_800) == [.move(WheelVector())], "extra finger lifting does not end the original week-long hold")
check(g.consume(device: 1, contacts: [pair()[0], Contact(id: 3, x: 0.8, y: 0.5)], time: 604_801) == [.finish], "original finger lifting finishes even with an extra finger remaining")
g.reset()
_ = g.consume(device: 1, contacts: pair(), time: 0)
_ = g.consume(device: 1, contacts: pair(), time: 1)
var replaced = pair(); replaced[1].id = 4
check(g.consume(device: 1, contacts: replaced, time: 1.1) == [.finish], "original trigger finger lifting finishes even if replaced")
g.reset()
_ = g.consume(device: 1, contacts: pair(), time: 0)
_ = g.consume(device: 1, contacts: pair(), time: 1)
check(g.consume(device: 1, contacts: [], time: 1.1) == [.finish], "zero contacts finish")
check(!g.active, "no held state after finish")
for i in 0..<8 {
    let a = Double(i) * Double.pi / 4
    check(wheelSector(WheelVector(x: sin(a), y: cos(a))) == i, "sector \(i)")
}
check(wheelSector(WheelVector()) == nil, "center dead zone")
check(wheelSector(WheelVector(x: 0.1, y: 0.1)) == nil, "near-center dead zone")
let border = Double.pi / 8 + 0.03
check(wheelSector(WheelVector(x: sin(border), y: cos(border)), previous: 0) == 0, "boundary hysteresis")
let suite = "local.magicwheel.tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
let original = Settings(defaults: defaults)
original.hold = 0.8; original.travel = 0.23; original.onRelease = true
original.slots[0] = "up"
let restored = Settings(defaults: defaults)
check(restored.hold == 0.8, "hold duration persists")
check(restored.travel == 0.23, "selection travel persists")
check(restored.onRelease, "release mode persists without initialization overwriting it")
check(restored.slots[0] == "up", "slot mapping persists")
let secondRestore = Settings(defaults: defaults)
check(secondRestore.onRelease && secondRestore.slots[0] == "up", "multiple launches retain saved settings")
defaults.removePersistentDomain(forName: suite)
check(KeyAction.find("option").key == 61 && KeyAction.find("option").held, "voice action uses held right Option")
for cursor in [CGPoint(x: 500, y: 500), CGPoint(x: 0, y: 0), CGPoint(x: -1400, y: 1300), CGPoint(x: 1900, y: -800)] {
    let size = CGSize(width: 320, height: 320)
    let origin = wheelOrigin(cursor: cursor, size: size)
    check(origin.x + 160 == cursor.x && origin.y + 160 == cursor.y, "wheel center matches cursor across displays and at edges")
}
// Three-finger mode must arm independently, track all contacts, and release on any lift.
let three = pair() + [Contact(id: 3, x: 0.8, y: 0.5)]
g.fingerCount = 3
check(g.consume(device: 1, contacts: pair(), time: 0).isEmpty, "two fingers cannot arm three-finger mode")
check(g.consume(device: 1, contacts: three, time: 0.1).isEmpty, "third finger arms a new hold")
check(g.consume(device: 1, contacts: three, time: 0.6) == [.show, .move(WheelVector())], "three-finger stationary hold opens")
let movedThree = three.map { Contact(id: $0.id, x: $0.x + 0.14, y: $0.y) }
if case .move(let v) = g.consume(device: 1, contacts: movedThree, time: 0.7).first {
    check(abs(v.x - 1) < 1e-8, "three-finger centroid movement")
} else { check(false, "three-finger movement effect") }
check(g.consume(device: 1, contacts: pair(), time: 0.8) == [.finish], "lifting any of three fingers finishes")
check(g.consume(device: 1, contacts: three, time: 1).isEmpty, "three fingers must all lift before rearming")
g.reset()
_ = g.consume(device: 1, contacts: three, time: 0)
_ = g.consume(device: 1, contacts: three, time: 1)
check(g.consume(device: 1, contacts: three + [Contact(id: 4, x: 0.9, y: 0.6)], time: 1.1) == [.move(WheelVector())], "fourth finger preserves three-finger wheel")
g.reset()
_ = g.consume(device: 1, contacts: three, time: 0)
_ = g.consume(device: 1, contacts: three, time: 1)
g.fingerCount = 2
check(!g.active, "changing finger mode clears active state")
check(wheelSector(WheelVector(x: 1), count: 0) == nil, "empty wheel cannot select or send keys")
for count in [1, 2, 3, 5, 7, 12, 24, 64, 130] {
    for rotation in [0.0, 0.3, Double.pi, 2 * Double.pi - 0.01, -1.2] {
        for i in 0..<count {
            let angle = rotation + Double(i) * 2 * Double.pi / Double(count)
            check(wheelSector(WheelVector(x: sin(angle), y: cos(angle)), count: count, rotation: rotation) == i, "rotated dynamic sector count=\(count), slot=\(i)")
        }
    }
}
check(abs(normalizedAngle(-0.1) - (2 * .pi - 0.1)) < 1e-10, "counterclockwise rotation wraps")
check(abs(normalizedAngle(2 * .pi + 0.2) - 0.2) < 1e-10, "clockwise rotation wraps")
let shortcut = KeyAction.shortcut("Command+Shift+S")!
check(shortcut.key == 1 && shortcut.flags.contains(.maskCommand) && shortcut.flags.contains(.maskShift), "free typed shortcut has correct key and modifiers")
check(KeyAction.shortcut("⌘⇧S")!.key == shortcut.key, "symbol shortcut entry")
check(KeyAction.shortcut("Right Option")!.key == 61 && KeyAction.shortcut("Right Option")!.held, "free typed right Option stays right-sided and held")
check(KeyAction.shortcut("F5")!.key == 96, "function key entry")
check(KeyAction.shortcut("Ctrl+Left")!.key == 123, "navigation shortcut entry")
check(KeyAction.shortcut("NoSuchKey") == nil, "unknown shortcut rejected")
check(KeyAction.shortcut("Command+") == nil, "missing main key rejected")
check(KeyAction.shortcut("Command+Command+A") == nil, "duplicate modifiers rejected")
check(!KeyAction.find("").enabled && !KeyAction.find("NoSuchKey").enabled, "blank and invalid keys cannot fall back to voice input")
check(KeyAction.find("text:你好🙂").text == "你好🙂", "free typed Unicode text retained")
check(KeyAction.shortcut("+")!.key == 24 && KeyAction.shortcut("+")!.flags.contains(.maskShift), "literal plus key entry")
check(KeyAction.shortcut("Command++")!.flags.contains(.maskCommand), "shortcut with plus as main key")
let dynamicSuite = "local.magicwheel.dynamic-tests." + UUID().uuidString
let dynamicDefaults = UserDefaults(suiteName: dynamicSuite)!
let dynamic = Settings(defaults: dynamicDefaults)
dynamicDefaults.set(3, forKey: "fingers"); dynamic.rotation = 1.2; dynamic.slots = ["option", "Command+Shift+S", "text:你好🙂", ""]
let dynamicRestore = Settings(defaults: dynamicDefaults)
check(dynamicRestore.fingers == 2 && dynamicRestore.rotation == 1.2, "legacy three-finger preference migrates to fixed two-finger trigger without changing rotation")
check(dynamicRestore.slots == dynamic.slots, "variable slot count and free typed values persist")
check(dynamicRestore.actions[1].key == 1 && dynamicRestore.actions[2].text != nil, "restored values resolve to correct actions")
dynamic.slots = []
check(Settings(defaults: dynamicDefaults).slots.isEmpty, "zero slots persist without restoring default eight")
dynamicDefaults.removePersistentDomain(forName: dynamicSuite)
let fastSuite = "local.magicwheel.fast-tests." + UUID().uuidString
let fastDefaults = UserDefaults(suiteName: fastSuite)!
let fast = Settings(defaults: fastDefaults); fast.hold = 0.05
check(Settings(defaults: fastDefaults).hold == 0.30, "legacy fast hold is raised to the anti-tap minimum")
fast.hold = 0.01
check(Settings(defaults: fastDefaults).hold == 0.30, "saved hold below minimum is clamped")
fastDefaults.removePersistentDomain(forName: fastSuite)
g.reset(); g.holdDuration = 0.05
_ = g.consume(device: 1, contacts: pair(), time: 0)
check(g.consume(device: 1, contacts: pair(), time: 0.049).isEmpty, "short hold still respects its threshold")
check(g.consume(device: 1, contacts: pair(), time: 0.15).isEmpty, "a brief tap cannot open with a legacy fast hold")
check(g.consume(device: 1, contacts: [], time: 0.16).isEmpty, "tap release has no finish action")
for duration in [0.05, 0.1, 0.2, 0.29] {
    g.reset()
    _ = g.consume(device: 1, contacts: pair(), time: 0)
    check(g.consume(device: 1, contacts: pair(), time: duration).isEmpty, "short contact stays invisible")
    check(g.consume(device: 1, contacts: [], time: duration + 0.001).isEmpty, "short contact release never fires")
}
g.reset()
_ = g.consume(device: 1, contacts: pair(), time: 0)
g.blockUntilLift()
check(g.consume(device: 1, contacts: pair(), time: 1).isEmpty, "click blocks hold even if fingers stay down")
_ = g.consume(device: 1, contacts: [], time: 1.1)
_ = g.consume(device: 1, contacts: pair(), time: 2)
check(g.consume(device: 1, contacts: pair(), time: 2.31).contains(.show), "fresh hold works after click and lift")
g.blockUntilLift()
check(g.consume(device: 1, contacts: pair(), time: 3).isEmpty, "click cancels active gesture until all fingers lift")
g.reset(); g.blockUntilLift()
_ = g.consume(device: 1, contacts: pair(), time: 0)
check(g.consume(device: 1, contacts: pair(), time: 1).isEmpty, "click arriving before contact frame also blocks")
let beforeBoundary = wheelIndicatorOffset(WheelVector(x: 0.269, y: 0))
let afterBoundary = wheelIndicatorOffset(WheelVector(x: 0.271, y: 0))
check(abs(afterBoundary.x - beforeBoundary.x - 0.24) < 1e-8, "indicator crosses dead zone continuously")
check(wheelIndicatorOffset(WheelVector(x: 0.1, y: 0)).x == 12, "indicator moves even inside dead zone")
check(abs(wheelIndicatorOffset(WheelVector(x: 2, y: 2)).length - 148) < 1e-8, "diagonal movement clamps at rim")
check(wheelIndicatorOffset(WheelVector()) == WheelVector(), "return to anchor returns indicator to center")
check(wheelIndicatorOffset(WheelVector(x: .nan, y: 0)) == WheelVector(), "invalid position does not reach renderer")
let stableTravel = GestureCore()
stableTravel.travel = 0.1
_ = stableTravel.consume(device: 1, contacts: pair(), time: 0)
_ = stableTravel.consume(device: 1, contacts: pair(), time: 0.5)
stableTravel.travel = 0.25
if case .move(let vector) = stableTravel.consume(device: 1, contacts: pair(0.05), time: 0.6).first {
    check(abs(vector.x - 0.5) < 1e-8, "selection speed remains fixed throughout one gesture")
} else { check(false, "active movement is produced") }
check(KeyAction.shortcut("打开轮盘设置")?.operation == .settings, "app operation resolves through the shared input field")
let editSuite = "local.magicwheel.edit-tests." + UUID().uuidString
let editDefaults = UserDefaults(suiteName: editSuite)!
let editing = Settings(defaults: editDefaults)
editing.slots = ["option", "return", "text:你好🙂", ""]
check(editing.updateSlot(1, input: "Command+Shift+S", textMode: false), "complete shortcut saves immediately")
check(Settings(defaults: editDefaults).slots[1] == "Command+Shift+S", "auto-save survives restart without Apply")
check(!editing.updateSlot(1, input: "Command+", textMode: false), "incomplete shortcut stays a draft")
check(Settings(defaults: editDefaults).slots[1] == "Command+Shift+S", "incomplete typing preserves last valid persisted action")
check(editing.updateSlot(1, input: "回车", textMode: false) && editing.actions[1].key == 36, "suggestion uses immediate save path")
check(editing.updateSlot(3, input: "你好🙂", textMode: true), "literal Unicode auto-saves")
check(editing.updateSlot(3, input: "", textMode: true) && !editing.actions[3].enabled, "empty entry clears action immediately")
let beforeSwap = editing.slots
check(editing.insertSlot(0, before: 3) == 2, "sector drop inserts action")
check(editing.slots == [beforeSwap[1], beforeSwap[2], beforeSwap[0], beforeSwap[3]], "insertion shifts intervening slots without swapping")
check(Settings(defaults: editDefaults).slots == editing.slots, "sector order persists after restart")
let afterSwap = editing.slots
check(editing.insertSlot(0, before: 0) == nil && editing.insertSlot(-1, before: 2) == nil && editing.insertSlot(1, before: 5) == nil, "same or invalid drop cannot reorder")
check(editing.slots == afterSwap && !editing.updateSlot(5, input: "Space", textMode: false), "invalid selection cannot alter settings")
editDefaults.removePersistentDomain(forName: editSuite)
let appearanceSuite = "local.magicwheel.appearance-tests." + UUID().uuidString
let appearanceDefaults = UserDefaults(suiteName: appearanceSuite)!
let styled = Settings(defaults: appearanceDefaults)
styled.slots = ["option", "return", "paste"]
check(styled.appearances == Array(repeating: SlotAppearance(), count: 3), "legacy wheels migrate with default labels and icons")
let voiceStyle = SlotAppearance(name: "语音输入", icon: "mic", showName: true, showIcon: true)
styled.setAppearance(voiceStyle, at: 0)
check(styled.actions[0].key == 61 && styled.actions[0].held, "custom appearance cannot change voice key behavior")
check(Settings(defaults: appearanceDefaults).appearance(at: 0) == voiceStyle, "custom name and icon persist immediately")
for showName in [false, true] {
    for showIcon in [false, true] {
        let style = SlotAppearance(name: "语音输入", icon: "🎙️", showName: showName, showIcon: showIcon)
        styled.setAppearance(style, at: 0)
        check(style.visibleName(for: styled.actions[0]) == (showName ? "语音输入" : ""), "name visibility independent of icon")
        check(style.visibleIcon(for: styled.actions[0]) == (showIcon ? "🎙️" : ""), "icon visibility independent of name")
        check(Settings(defaults: appearanceDefaults).appearance(at: 0) == style, "all four display combinations persist")
    }
}
styled.setAppearance(voiceStyle, at: 0)
_ = styled.insertSlot(0, before: 3)
check(styled.actions[2].key == 61 && styled.appearance(at: 2) == voiceStyle, "drag insertion carries appearance with action")
check(Settings(defaults: appearanceDefaults).appearances == styled.appearances, "reordered appearances survive restart")
styled.removeSlot(1)
check(styled.slots == ["return", "option"] && styled.appearance(at: 1) == voiceStyle, "deleting middle sector preserves remaining associations")
styled.slots.append("")
check(styled.appearance(at: 2) == SlotAppearance(), "new sector starts with its own defaults")
_ = styled.updateSlot(1, input: "Return", textMode: false)
check(styled.appearance(at: 1) == voiceStyle && styled.actions[1].key == 36, "changing binding preserves custom appearance")
styled.setAppearance(SlotAppearance(), at: 1)
check(styled.appearance(at: 1).visibleName(for: styled.actions[1]) == styled.actions[1].label, "restore default follows current action name")
let safeAppearance = styled.appearances
styled.setAppearance(voiceStyle, at: 20); styled.removeSlot(-1)
check(styled.appearances == safeAppearance, "invalid edit or delete cannot corrupt appearance")
appearanceDefaults.set(Data("invalid".utf8), forKey: "slotAppearances")
check(Settings(defaults: appearanceDefaults).appearances == Array(repeating: SlotAppearance(), count: styled.slots.count), "malformed saved appearance safely uses defaults")
appearanceDefaults.removePersistentDomain(forName: appearanceSuite)
for distance in [0.07, 0.25] {
    let selection = GestureCore(); selection.holdDuration = 0.05; selection.travel = distance
    _ = selection.consume(device: 1, contacts: pair(), time: 0)
    _ = selection.consume(device: 1, contacts: pair(), time: 0.31)
    let shifted = pair().map { Contact(id: $0.id, x: $0.x + 0.025, y: $0.y) }
    if case .move(let v) = selection.consume(device: 1, contacts: shifted, time: 0.4).first {
        check((wheelSector(v) != nil) == (distance == 0.07), "same finger displacement selects at short distance and remains in center at long distance")
    } else { check(false, "selection-distance movement produced") }
}
let modes: [TriggerMode] = [.onEntry, .onRelease, .whileInside]
let targetFocus = WheelFocusSnapshot(pid: 10)
let otherFocus = WheelFocusSnapshot(pid: 20)
check(WheelFocusPolicy.destination(targetPID: 10, frontmost: targetFocus) == .target, "original application is a ready action target")
check(WheelFocusPolicy.destination(targetPID: 10, frontmost: otherFocus) == .other, "another regular application cancels the target")
check(WheelFocusPolicy.destination(targetPID: 10, frontmost: WheelFocusSnapshot(pid: 20, keyboardPID: 10)) == .target, "actual keyboard focus takes precedence over activation notifications")
check(WheelFocusPolicy.destination(targetPID: 10, frontmost: nil) == .transient, "activation gaps preserve the confirmed action")
check(WheelFocusPolicy.destination(targetPID: nil, frontmost: targetFocus) == .other, "missing original target cannot receive an action")
for helperPID in [pid_t(30), 40, 50] {
    let helper = WheelFocusSnapshot(pid: helperPID, isAuxiliary: true)
    check(WheelFocusPolicy.destination(targetPID: 10, frontmost: helper) == .transient, "any auxiliary application can temporarily own focus")
    let keyboardTarget = WheelFocusSnapshot(pid: helperPID, isAuxiliary: true, keyboardPID: 10)
    check(WheelFocusPolicy.destination(targetPID: 10, frontmost: keyboardTarget) == .target, "keyboard recipient is ready despite auxiliary activation")
    let helperKeyboard = WheelFocusSnapshot(pid: helperPID, isAuxiliary: true, keyboardPID: helperPID)
    check(WheelFocusPolicy.destination(targetPID: 10, frontmost: helperKeyboard) == .transient, "auxiliary keyboard focus waits for the original recipient")
}
for index in modes.indices {
    var quick = WheelActivation()
    _ = quick.move(to: index)
    let immediate = quick.commit(modes: modes, enabled: [true, true, true])
    let expectedEntry: [WheelActionEffect] = modes[index] == .onEntry ? [.tap(index)] : modes[index] == .whileInside ? [.hold(index)] : []
    check(immediate == expectedEntry && quick.committed == index, "selection commits immediately in \(modes[index].rawValue) mode")
    let expectedExit: [WheelActionEffect] = modes[index] == .onRelease ? [.tap(index)] : modes[index] == .whileInside ? [.release] : []
    check(quick.finish(cancel: false, modes: modes, enabled: [true,true,true]) == expectedExit, "quick normal exit balances immediate \(modes[index].rawValue) action")
    check(quick.finish(cancel: false, modes: modes, enabled: [true,true,true]).isEmpty, "quick exit cannot fire twice")
    _ = quick.move(to: index)
    check(quick.finish(cancel: true, modes: modes, enabled: [true,true,true]).isEmpty, "quick cancellation never executes a pending sector")
    _ = quick.move(to: index); _ = quick.move(to: nil)
    check(quick.finish(cancel: false, modes: modes, enabled: [true,true,true]).isEmpty, "quick return to center disarms final selection")
    _ = quick.move(to: index)
    check(quick.finish(cancel: false, modes: modes, enabled: [false,false,false]).isEmpty, "quick blank sector never emits an event")
    _ = quick.move(to: index)
    check(quick.finish(cancel: false, modes: [], enabled: []).isEmpty, "quick out-of-range sector never emits an event")
    _ = quick.move(to: (index + 1) % modes.count); _ = quick.move(to: index)
    check(quick.finish(cancel: false, modes: modes, enabled: [true,true,true]) == [.tap(index)], "quick exit confirms only the final sector")
}
var activation = WheelActivation()
check(activation.move(to: 0).isEmpty, "selection updates candidate before applying its mode")
check(activation.commit(modes: modes, enabled: [true,true,true]) == [.tap(0)] && activation.phase == .fired, "entry mode taps immediately without a dwell")
check(activation.commit(modes: modes, enabled: [true,true,true]).isEmpty, "immediate entry commits only once")
check(activation.commit(modes: modes, enabled: [true,true,true]).isEmpty, "staying in entry sector cannot repeatedly fire")
check(activation.finish(cancel: false, modes: modes, enabled: [true,true,true]).isEmpty, "entry action is not sent again on closing")
_ = activation.move(to: 1)
check(activation.commit(modes: modes, enabled: [true,true,true]).isEmpty && activation.phase == .releaseReady, "release mode only arms")
check(activation.finish(cancel: false, modes: modes, enabled: [true,true,true]) == [.tap(1)], "release mode fires final selected action once")
check(activation.finish(cancel: false, modes: modes, enabled: [true,true,true]).isEmpty, "repeated close cannot duplicate release action")
_ = activation.move(to: 1); _ = activation.commit(modes: modes, enabled: [true,true,true])
check(activation.finish(cancel: true, modes: modes, enabled: [true,true,true]).isEmpty, "cancel never fires armed release action")
_ = activation.move(to: 1); _ = activation.commit(modes: modes, enabled: [true,true,true])
_ = activation.move(to: nil)
check(activation.finish(cancel: false, modes: modes, enabled: [true,true,true]).isEmpty, "return to center disarms release action")
_ = activation.move(to: 1); _ = activation.commit(modes: modes, enabled: [true,true,true])
_ = activation.move(to: 0)
check(activation.finish(cancel: false, modes: modes, enabled: [true,true,true]) == [.tap(0)], "quick final sector fires instead of the previously armed action")
_ = activation.move(to: 2)
check(activation.commit(modes: modes, enabled: [true,true,true]) == [.hold(2)] && activation.phase == .holding, "inside mode holds on selection")
check(activation.move(to: 1) == [.release], "leaving held sector releases immediately")
check(activation.commit(modes: modes, enabled: [true,true,true]).isEmpty && activation.phase == .releaseReady, "mixed release sector arms after old hold is released")
check(activation.finish(cancel: false, modes: modes, enabled: [true,true,true]) == [.tap(1)], "mixed-mode finish fires only final sector")
for canceled in [false, true] {
    _ = activation.move(to: 2); _ = activation.commit(modes: modes, enabled: [true,true,true])
    check(activation.finish(cancel: canceled, modes: modes, enabled: [true,true,true]) == [.release], "normal and canceled exit always release held key")
    check(activation.candidate == nil && activation.committed == nil && activation.phase == .idle, "exit clears all interaction state")
}
_ = activation.move(to: 2); _ = activation.commit(modes: modes, enabled: [true,true,true])
check(activation.move(to: nil) == [.release], "center entry releases held key")
_ = activation.move(to: 0); _ = activation.commit(modes: modes, enabled: [true,true,true])
_ = activation.move(to: nil); _ = activation.move(to: 0)
check(activation.commit(modes: modes, enabled: [true,true,true]) == [.tap(0)], "leaving and re-entering allows a new entry action")
_ = activation.finish(cancel: true, modes: modes, enabled: [true,true,true]); _ = activation.move(to: 0)
check(activation.commit(modes: modes, enabled: [false,true,true]).isEmpty && activation.phase == .inactive, "blank sector cannot emit keys or display a false press")
let modeSuite = "local.magicwheel.mode-tests." + UUID().uuidString
let modeDefaults = UserDefaults(suiteName: modeSuite)!
modeDefaults.set(0.45, forKey: "hold"); modeDefaults.set(true, forKey: "onRelease")
modeDefaults.set(["option", "return", "text:hello", "settings"], forKey: "slots")
let customModes = Settings(defaults: modeDefaults)
check(customModes.triggers == [.whileInside, .onRelease, .onRelease, .onRelease], "legacy ordinary release preference and held modifier behavior migrate")
customModes.setTrigger(.onEntry, at: 1); customModes.setTrigger(.onRelease, at: 0)
check(Settings(defaults: modeDefaults).triggers == [.onRelease, .onEntry, .onRelease, .onRelease], "per-sector modes persist independently")
customModes.setTrigger(.whileInside, at: 2); customModes.setTrigger(.whileInside, at: 3)
check(customModes.triggers[2] == .onRelease && customModes.triggers[3] == .onRelease, "text and app operations reject a nonsensical hold mode")
customModes.setTrigger(.whileInside, at: 1)
check(customModes.trigger(at: 1) == .whileInside && customModes.actions[1].key == 36, "ordinary key can hold without becoming a modifier")
customModes.resetAppearance(at: 1)
check(customModes.trigger(at: 1) == .whileInside, "restoring appearance cannot reset trigger behavior")
_ = customModes.insertSlot(0, before: 2)
check(customModes.triggers[0] == .whileInside && customModes.triggers[1] == .onRelease, "drag insertion carries trigger modes with actions")
customModes.removeSlot(0)
check(customModes.actions[0].key == 61 && customModes.trigger(at: 0) == .onRelease, "deleting preserves remaining trigger associations")
let shortcutID = "7E42B2A6-580A-4B58-8E1B-95B913533650"
let systemWorkflow = SystemShortcut(identifier: shortcutID, name: "清空 (当前) 输入框 🙂")!
check(SystemShortcut.decode(systemWorkflow.storedValue) == systemWorkflow, "system systemWorkflow reference round-trips Unicode and parentheses")
check(SystemShortcut.decode("mac-shortcut:bad") == nil && SystemShortcut(identifier: "invalid;echo", name: "bad") == nil, "malformed references cannot become executable shortcut IDs")
let malicious = SystemShortcut(identifier: shortcutID, name: "$(touch /tmp/not-executed) `echo bad`")!
check(malicious.runArguments == ["run", shortcutID], "systemWorkflow names never enter a shell or execution argument")
let otherID = "186852A0-30A3-46A0-A150-6D136D935191"
let parsed = SystemShortcut.parseList("\(systemWorkflow.name) (\(shortcutID))\n回车 (\(otherID.lowercased()))\n重复 (\(shortcutID))\nnoise\n")
check(parsed.count == 2 && parsed.contains(systemWorkflow), "CLI list parses trailing identifiers and deduplicates references")
check(SystemShortcut.parseList("").isEmpty, "empty system systemWorkflow library is valid")
let shortcutAction = KeyAction.find(systemWorkflow.storedValue)
check(shortcutAction.systemShortcutReference == systemWorkflow && !shortcutAction.canHold && shortcutAction.operation == nil, "system workflow is an action, never a held keyboard key")
customModes.slots = ["option", "return"]
customModes.setTrigger(.whileInside, at: 0)
customModes.assignShortcut(systemWorkflow, at: 0)
check(customModes.actions[0].systemShortcutReference == systemWorkflow && customModes.trigger(at: 0) == .onRelease, "replacing held key with workflow chooses a valid release trigger")
check(Settings(defaults: modeDefaults).actions[0].systemShortcutReference == systemWorkflow, "workflow identifier and displayed name persist")
customModes.setTrigger(.whileInside, at: 0)
check(customModes.trigger(at: 0) == .onRelease, "workflow cannot be set to hold mode")
_ = customModes.insertSlot(0, before: 2)
check(customModes.actions[1].systemShortcutReference == systemWorkflow && customModes.trigger(at: 1) == .onRelease, "workflow follows drag insertion")
check(customModes.updateSlot(1, input: "Esc", textMode: false) && customModes.actions[1].systemShortcutReference == nil, "typing a key replaces a system workflow binding")
let client = ShortcutsClient()
var requests: [[String]] = []
client.execute = { arguments, completion in
    requests.append(arguments)
    completion(.success(arguments.first == "list" ? "\(systemWorkflow.name) (\(shortcutID))" : ""))
}
var listed: [SystemShortcut] = []
client.list { if case .success(let choices) = $0 { listed = choices } }
client.run(systemWorkflow) { _ in }
check(listed == [systemWorkflow] && requests == [["list", "--show-identifiers"], ["run", shortcutID]], "system bridge lists identifiers and invokes selected identifier only")
client.execute = { _, completion in completion(.success("unrecognized list format")) }
var listFailed = false
client.list { if case .failure = $0 { listFailed = true } }
check(listFailed, "unrecognized system list format is an error, not a false empty library")
client.execute = { _, completion in completion(.failure(.runFailed)) }
var runFailed = false
client.run(systemWorkflow) { if case .failure = $0 { runFailed = true } }
check(runFailed, "system execution errors propagate to the application")
modeDefaults.removePersistentDomain(forName: modeSuite)
let recordings: [(UInt16, CGEventFlags, String)] = [(36, [], "回车"), (40, [.maskControl, .maskShift], "⌃⇧K"), (49, .maskCommand, "⌘空格"), (61, .maskAlternate, "右 Option"), (58, .maskAlternate, "左 Option"), (53, [], "Esc")]
for (code, flags, label) in recordings {
    let key = RecordedKey.capture(key: code, flags: flags)
    check(key.label == label, "recorded key display: \(label)")
    check(RecordedKey.decode(key.storedValue) == key, "recorded key round trip")
    check(KeyAction.find(key.storedValue).key == code, "recorded key maps to original physical code")
    check(customModes.updateSlot(0, input: key.storedValue, textMode: false), "recorded key saves without text parsing")
}
check(KeyAction.find(RecordedKey.capture(key: 49, flags: .maskCommand).storedValue).systemShortcut, "recorded Spotlight uses system delivery")
check(KeyAction.find(RecordedKey.capture(key: 61, flags: .maskAlternate).storedValue).held, "recorded right Option is a modifier")
check(RecordedKey.capture(key: 61, flags: .maskAlternate).flags & 0x40 != 0, "right Option preserves right-side device flag")
check(RecordedKey.decode("recorded:bad") == nil, "invalid recorded binding rejected")
modeDefaults.removePersistentDomain(forName: modeSuite)
// Profile migration, independent editing, and runtime snapshots.
let profileSuite = "local.magicwheel.profile-tests." + UUID().uuidString
let profileDefaults = UserDefaults(suiteName: profileSuite)!
profileDefaults.set(0.1, forKey: "hold"); profileDefaults.set(0.12, forKey: "travel")
profileDefaults.set(["", "return", "settings", "spotlight"], forKey: "slots")
profileDefaults.set(0.8, forKey: "rotation"); profileDefaults.set(true, forKey: "onRelease")
let legacyStyles = [SlotAppearance(), SlotAppearance(name: "发送", icon: "paperplane", showName: false, trigger: .whileInside), SlotAppearance(trigger: .onRelease), SlotAppearance(icon: "magnifyingglass")]
profileDefaults.set(try! JSONEncoder().encode(legacyStyles), forKey: "slotAppearances")
let profiles = Settings(defaults: profileDefaults)
let originalGlobal = profiles.editingWheel
check(originalGlobal.slots == ["", "return", "settings", "spotlight"] && originalGlobal.appearances == legacyStyles && originalGlobal.rotation == 0.8, "legacy wheel migrates without changing mappings, styles or rotation")
check(profiles.wheel(for: nil) == originalGlobal && profiles.selectedApplicationID == nil, "editor starts at global configuration")
check(!profiles.addApplication(id: "", name: "Unknown", path: ""), "application without bundle identifier is rejected")
check(profiles.addApplication(id: "test.a", name: "Same Name", path: "/A.app"), "first application profile created")
check(profiles.editingWheel == originalGlobal, "new application starts with global wheel")
profiles.slots = ["option", "return"]
profiles.appearances = [SlotAppearance(name: "A", icon: "mic", showIcon: false, trigger: .whileInside), SlotAppearance(trigger: .onEntry)]
profiles.rotation = 1.4
let appA = profiles.editingWheel
check(profiles.wheel(for: "test.a") == appA && profiles.wheel(for: "unconfigured") == originalGlobal, "runtime uses matching profile and otherwise global while editor is on an app")
check(profiles.addApplication(id: "test.b", name: "Same Name", path: "/B.app"), "same-named applications are distinct by bundle identifier")
check(profiles.editingWheel == originalGlobal, "second app copies global rather than previously selected app")
profiles.slots = ["escape", "tab", "copy"]
profiles.rotation = 2.1
let appB = profiles.editingWheel
profiles.selectApplication("test.a")
check(profiles.editingWheel == appA && profiles.wheel(for: "test.b") == appB, "switching applications isolates count, mappings, appearance and rotation")
let frozen = profiles.wheel(for: "test.a")
profiles.slots[0] = "space"
check(frozen == appA && profiles.wheel(for: "test.a") != frozen, "runtime value snapshot stays frozen during editor changes")
profiles.selectApplication(nil)
check(profiles.editingWheel == originalGlobal, "application edits never overwrite global wheel")
let reloadProfiles = Settings(defaults: profileDefaults)
check(reloadProfiles.applicationWheels.count == 2 && reloadProfiles.wheel(for: "test.b") == appB && reloadProfiles.editingWheel == originalGlobal, "restart restores all independent profiles and defaults to global editor")
check(profileDefaults.stringArray(forKey: "slots") == originalGlobal.slots, "legacy keys always store global, never last edited application")
reloadProfiles.selectApplication("test.b")
reloadProfiles.removeSelectedApplication()
check(reloadProfiles.selectedApplicationID == nil && reloadProfiles.wheel(for: "test.b") == originalGlobal && reloadProfiles.applicationWheels.count == 1, "deleting profile returns editor and runtime to global")
check(Settings(defaults: profileDefaults).applicationWheels.count == 1, "profile deletion persists")
reloadProfiles.selectApplication("does.not.exist")
check(reloadProfiles.selectedApplicationID == nil, "invalid selection cannot redirect edits")
reloadProfiles.selectApplication("test.a")
reloadProfiles.slots = []
check(reloadProfiles.wheel(for: "test.a").slots.isEmpty && !reloadProfiles.wheel(for: nil).slots.isEmpty, "empty application wheel stays empty rather than falling back")
reloadProfiles.selectApplication(nil); reloadProfiles.slots = []
check(reloadProfiles.wheel(for: nil).slots.isEmpty, "empty global persists independently")
// Scene routing, persistence, migration and independent editing.
let sceneSettings = Settings(defaults: profileDefaults)
let sceneGlobal = sceneSettings.wheel(for: nil)
let sceneApp = sceneSettings.wheel(for: "test.a")
check(sceneSettings.sceneWheels.isEmpty && sceneSettings.wheel(for: "test.a", scene: .textInput) == sceneApp, "unconfigured scene retains app wheel")
sceneSettings.selectApplication("test.a")
sceneSettings.addScene(.textInput)
check(sceneSettings.editingWheel == sceneGlobal && sceneSettings.selectedScene == .textInput, "new scene copies global independently of selected app")
sceneSettings.slots = ["clearText", "virtualKeyboard", "paste"]
sceneSettings.rotation = 0.45
sceneSettings.setAppearance(SlotAppearance(name: "Typing", icon: "keyboard", trigger: .onRelease), at: 0)
let textScene = sceneSettings.editingWheel
check(sceneSettings.wheel(for: "test.a", scene: .textInput) == textScene && sceneSettings.wheel(for: nil, scene: .textInput) == textScene, "configured scene overrides app and global wheels")
check(sceneSettings.wheel(for: "test.a") == sceneApp && sceneSettings.wheel(for: nil) == sceneGlobal, "scene edits leave app and global untouched")
sceneSettings.selectApplication(nil)
sceneSettings.selectTarget(.scene(.textInput))
check(sceneSettings.editingWheel == textScene, "scene selection restores actions, appearance and rotation")
sceneSettings.addScene(.textInput)
check(sceneSettings.sceneWheels.count == 1 && sceneSettings.editingWheel == textScene, "adding existing scene preserves customizations")
let restoredScenes = Settings(defaults: profileDefaults)
check(restoredScenes.selectedTarget == .global && restoredScenes.wheel(for: "test.a", scene: .textInput) == textScene, "scene persists across restart without changing initial editing target")
restoredScenes.selectTarget(.scene(.textInput)); restoredScenes.slots = []
check(restoredScenes.wheel(for: "test.a", scene: .textInput).slots.isEmpty, "explicitly empty scene does not fall back")
check(sceneSettings.wheel(for: "test.a", scene: .textInput) == textScene, "existing value snapshot remains independent")
restoredScenes.removeSelectedScene()
check(restoredScenes.selectedTarget == .global && restoredScenes.wheel(for: "test.a", scene: .textInput) == sceneApp, "scene removal restores app routing and global editor")
check(Settings(defaults: profileDefaults).sceneWheels.isEmpty, "scene removal persists")
restoredScenes.selectTarget(.scene(.textInput))
check(restoredScenes.selectedTarget == .global, "missing scene cannot redirect edits")
var oldLibrary = try! JSONSerialization.jsonObject(with: profileDefaults.data(forKey: "wheelLibrary.v1")!) as! [String: Any]
oldLibrary.removeValue(forKey: "scenes")
profileDefaults.set(try! JSONSerialization.data(withJSONObject: oldLibrary), forKey: "wheelLibrary.v1")
let migratedScenes = Settings(defaults: profileDefaults)
check(migratedScenes.sceneWheels.isEmpty && migratedScenes.wheel(for: "test.a") == sceneApp && migratedScenes.wheel(for: nil) == sceneGlobal, "pre-scene library migrates without losing app or global configurations")
let illegalWheel = WheelConfiguration(slots: [systemWorkflow.storedValue, "return"], appearances: [SlotAppearance(trigger: .whileInside), SlotAppearance(trigger: .whileInside)], rotation: 0, onRelease: false)
let illegalLibrary = WheelLibrary(global: illegalWheel, applications: [ApplicationWheel(id: "test.workflow", name: "Workflow", path: "", wheel: illegalWheel)])
profileDefaults.set(try! JSONEncoder().encode(illegalLibrary), forKey: "wheelLibrary.v1")
let repaired = Settings(defaults: profileDefaults)
check(repaired.triggers == [.onEntry, .whileInside] && repaired.appearances[0].trigger == .onEntry, "invalid global workflow hold is repaired on read, normal key hold preserved")
repaired.selectApplication("test.workflow")
check(repaired.triggers == [.onEntry, .whileInside], "invalid workflow hold repaired in app profile")
_ = repaired.insertSlot(0, before: 2)
check(repaired.triggers == [.whileInside, .onEntry], "workflow repair survives insertion")
repaired.setTrigger(.whileInside, at: 1)
check(repaired.trigger(at: 1) == .onEntry, "app workflow rejects hold edits")
let persistedLibrary = try! JSONDecoder().decode(WheelLibrary.self, from: profileDefaults.data(forKey: "wheelLibrary.v1")!)
check(persistedLibrary.applications[0].wheel.appearances[1].trigger == .onEntry, "serialized app workflow cannot retain invalid hold mode")
for mode in [TriggerMode.onEntry, .onRelease] {
    repaired.setTrigger(mode, at: 1)
    repaired.selectApplication(nil); repaired.selectApplication("test.workflow")
    check(repaired.trigger(at: 1) == mode, "both legal workflow modes survive profile switching")
}
for code in RecordedKey.manualKeyCodes {
    let value = RecordedKey.capture(key: code, flags: [.maskCommand, .maskShift])
    check(RecordedKey.decode(value.storedValue) == value && KeyAction.find(value.storedValue).key == code, "manual key choice round trips through same event mapping")
}
check(RecordedKey.capture(key: 61, flags: []).flags == CGEventFlags.maskAlternate.rawValue | 0x40, "manual right Option preserves physical side without pressing it")
check(RecordedKey.capture(key: 58, flags: .maskCommand).label == "⌘左 Option", "manual modifier combination display includes extra modifiers")
profileDefaults.removePersistentDomain(forName: profileSuite)
var virtual = VirtualKeyboardSelection(action: .empty)
check(virtual.recorded == nil, "virtual keyboard cannot save an empty selection")
virtual.select(61)
check(virtual.recorded?.key == 61 && virtual.recorded?.flags == CGEventFlags.maskAlternate.rawValue | 0x40, "virtual right Option is selectable without real events")
virtual.select(58); virtual.select(61)
check(virtual.recorded?.key == 58 && !virtual.contains(61), "virtual left and right modifiers toggle independently")
virtual.clear(); virtual.select(55); virtual.select(49)
check(virtual.recorded?.label == "⌘空格" && KeyAction.find(virtual.recorded!.storedValue).systemShortcut, "virtual Command Space retains system event delivery despite side flags")
let virtualReload = VirtualKeyboardSelection(action: KeyAction.find(virtual.recorded!.storedValue))
check(virtualReload.contains(55) && virtualReload.contains(49) && virtualReload.recorded == virtual.recorded, "virtual combination reopens with all selected keys preserved")
virtual.select(49)
check(virtual.recorded?.key == 55 && virtual.recorded?.modifier == true, "deselecting main key creates a modifier-only binding")
virtual.select(55)
check(virtual.recorded == nil, "deselecting final modifier clears the selection")
virtual.select(62); virtual.select(60); virtual.select(40)
check(virtual.recorded?.label == "⌃⇧K" && virtual.recorded!.flags & 0x2004 == 0x2004, "virtual multi-modifier combination preserves right-side flags")
virtual.select(36)
check(virtual.recorded?.key == 36 && !virtual.contains(40) && virtual.contains(62), "choosing another main key keeps latched modifiers")
virtual.clear()
check(virtual.recorded == nil && !virtual.contains(36), "clear selection resets main key and modifiers")
let bundledSymbols = SystemSymbolIndex.candidates(fallbackURL: URL(fileURLWithPath: CommandLine.arguments[1]), systemDirectory: nil)
check(bundledSymbols.count > 8000, "bundled catalog covers the full snapshot without depending on system metadata")
check(Set(bundledSymbols.map(\.name)).count == bundledSymbols.count, "catalog deduplicates names")
check(bundledSymbols.filter { $0.matches("麦克风") }.contains { $0.name == "mic.fill" }, "Chinese search includes filled variants")
check(bundledSymbols.filter { $0.matches("剪贴板") }.contains { $0.name == "doc.on.clipboard" }, "Chinese search matches compound names")
check(bundledSymbols.filter { $0.matches("CAMERA FILL") }.contains { $0.name == "camera.fill" }, "English search is case insensitive and supports multiple terms")
check(bundledSymbols.filter { $0.matches("camera.fill") }.contains { $0.name == "camera.fill" }, "exact dotted symbol name is searchable")
check(bundledSymbols.filter { $0.matches("date") }.contains { $0.name == "1.calendar" }, "search includes the system keyword metadata")
check(bundledSymbols.allSatisfy { $0.matches("  \n ") }, "whitespace search shows the full catalog")
check(bundledSymbols.filter { $0.matches("no-such-icon-zzzz") }.isEmpty, "unknown query has no results")
let currentSymbols = SystemSymbolIndex.candidates(fallbackURL: URL(fileURLWithPath: CommandLine.arguments[1]))
check(Set(bundledSymbols.map(\.name)).isSubset(of: Set(currentSymbols.map(\.name))), "system catalog merges with the bundled fallback")
// Theme migration and persistence must never alter key bindings or app profiles.
let themeSuite = "local.magicwheel.theme-tests.\(UUID().uuidString)"
let themeDefaults = UserDefaults(suiteName: themeSuite)!
let freshTheme = Settings(defaults: themeDefaults)
check(freshTheme.theme == .minimal, "new installations default to minimal")
themeDefaults.removePersistentDomain(forName: themeSuite)
themeDefaults.set(0.6, forKey: "hold")
themeDefaults.set(["return", "copy"], forKey: "slots")
let legacyTheme = Settings(defaults: themeDefaults)
check(legacyTheme.theme == .glass && legacyTheme.slots == ["return", "copy"], "existing settings retain glass and bindings")
legacyTheme.addApplication(id: "theme.app", name: "Theme App", path: "")
legacyTheme.slots = ["paste"]
let themeOriginalGlobal = legacyTheme.wheel(for: nil)
let originalApp = legacyTheme.wheel(for: "theme.app")
for theme in WheelTheme.allCases {
    legacyTheme.theme = theme
    let reloaded = Settings(defaults: themeDefaults)
    check(reloaded.theme == theme, "theme survives restart")
    check(reloaded.wheel(for: nil) == themeOriginalGlobal && reloaded.wheel(for: "theme.app") == originalApp, "theme preserves global and app bindings")
    legacyTheme.selectApplication(nil); legacyTheme.selectApplication("theme.app")
    check(legacyTheme.theme == theme, "theme applies consistently across app profiles")
}
check(WheelTheme.allCases == [.minimal, .glass], "theme menu exposes only supported themes")
for retired in ["frosted", "colorful", "gta", "cyberpunk"] {
    themeDefaults.set(retired, forKey: "wheelTheme")
    let migrated = Settings(defaults: themeDefaults)
    check(migrated.theme == .glass, "retired theme migrates to liquid glass")
    check(migrated.wheel(for: nil) == themeOriginalGlobal && migrated.wheel(for: "theme.app") == originalApp, "theme migration preserves global and app bindings")
}
themeDefaults.set("unknown-future-theme", forKey: "wheelTheme")
check(Settings(defaults: themeDefaults).theme == .glass, "unrecognized theme falls back safely for existing settings")
themeDefaults.removePersistentDomain(forName: themeSuite)
// Cursor lifecycle: success != actual invisibility, and every hide is balanced.
var hideCalls = 0, showCalls = 0, hideCount = 0
var allowCalls: [Bool] = []
var simulatedVisible = true, failHide = false, failShow = false
let cursorBackend = WheelCursor.Backend(allowBackground: { enabled in allowCalls.append(enabled); return true }, hide: {
    hideCalls += 1
    if failHide { return false }
    hideCount += 1; simulatedVisible = false; return true
}, show: {
    showCalls += 1
    if failShow { return false }
    hideCount -= 1; simulatedVisible = true; return true
}, visible: { simulatedVisible })
let cursor = WheelCursor(backend: cursorBackend)
check(cursor.begin() && hideCount == 1, "cursor acquires one hide request")
_ = cursor.begin()
check(hideCalls == 1 && hideCount == 1, "repeated begin never stacks hide counts")
simulatedVisible = true
check(!cursor.hidden && cursor.ownsHide, "successful API request does not imply real invisibility")
cursor.maintain(time: 1)
check(cursor.hidden && hideCount == 1 && showCalls == 1, "reappearance reasserts one balanced hide")
cursor.end(); cursor.end()
check(hideCount == 0 && cursor.restoreSucceeded && showCalls == 2 && allowCalls.last == false, "repeated close restores once and resets background property")
failHide = true
check(!cursor.begin() && !cursor.ownsHide && allowCalls.last == false, "failed hide cleans up connection property")
failHide = false; _ = cursor.begin(); failShow = true; cursor.end()
check(cursor.ownsHide && !cursor.restoreSucceeded, "failed restore retains ownership for retry")
failShow = false; cursor.end()
check(!cursor.ownsHide && hideCount == 0 && cursor.restoreSucceeded, "retry successfully restores cursor without losing count")
// Quick-text mode survives empty drafts, profile changes, and relaunches.
let textSuite = "local.magicwheel.quick-text-tests.\(UUID().uuidString)"
let textDefaults = UserDefaults(suiteName: textSuite)!
let textSettings = Settings(defaults: textDefaults)
let untouched = textSettings.slots[1]
check(textSettings.updateSlot(0, input: "", textMode: true), "empty text mode can be selected")
check(textSettings.slots[0] == "text:" && !textSettings.actions[0].enabled, "empty phrase keeps text mode but cannot execute")
let phrase = "  你好🙂\nCommand+A\n谢谢  "
check(textSettings.updateSlot(0, input: phrase, textMode: true), "multiline phrase saves")
check(textSettings.actions[0].text == phrase && !textSettings.actions[0].canHold, "literal phrase preserves whitespace and never becomes a key")
textSettings.language = .english
let reloadedText = Settings(defaults: textDefaults)
check(reloadedText.language == .english && reloadedText.actions[0].text == phrase, "language and phrase persist independently")
check(reloadedText.slots[1] == untouched, "editing text leaves other bindings intact")
check(KeyAction.find("text:回车").displayLabel(.english) == "回车", "language does not translate user phrases")
check(KeyAction.find("return").displayLabel(.english) == "Return", "built-in labels translate")
textSettings.addApplication(id: "test.quicktext", name: "Test", path: "")
_ = textSettings.updateSlot(0, input: "app phrase", textMode: true)
textSettings.selectApplication(nil)
check(textSettings.actions[0].text == phrase, "app phrase stays independent of global phrase")
_ = textSettings.updateSlot(0, input: "", textMode: true)
check(Settings(defaults: textDefaults).slots[0] == "text:", "cleared phrase reopens in text mode")
_ = textSettings.updateSlot(0, input: "return", textMode: false)
check(textSettings.actions[0].key == 36 && textSettings.actions[0].text == nil, "preset replaces text mode")
check(textSettings.updateSlot(0, input: phrase, textMode: true, sendReturn: true), "automatic Return can be enabled per text binding")
check(textSettings.actions[0].text == phrase && textSettings.actions[0].sendReturn && !textSettings.actions[0].canHold, "automatic Return preserves exact phrase and disallows holding")
check(Settings(defaults: textDefaults).actions[0].sendReturn, "automatic Return survives restart")
_ = textSettings.updateSlot(0, input: phrase + "🙂", textMode: true)
check(textSettings.actions[0].sendReturn, "typing more text preserves automatic Return")
_ = textSettings.updateSlot(0, input: "", textMode: true)
check(QuickTextBinding.decode(Settings(defaults: textDefaults).slots[0])?.sendReturn == true && !textSettings.actions[0].enabled, "empty draft retains automatic Return but stays disabled")
_ = textSettings.updateSlot(0, input: phrase, textMode: true, sendReturn: false)
check(textSettings.slots[0] == "text:" + phrase && !textSettings.actions[0].sendReturn, "disabling automatic Return restores legacy text behavior")
_ = textSettings.updateSlot(0, input: phrase, textMode: true, sendReturn: true)
textSettings.selectApplication("test.quicktext")
check(!textSettings.actions[0].sendReturn, "another scene retains its independent Return preference")
check(textSettings.copyWheel(from: .global) && textSettings.actions[0].sendReturn, "copying a wheel preserves automatic Return")
_ = textSettings.updateSlot(0, input: "return", textMode: false)
_ = textSettings.updateSlot(0, input: phrase, textMode: true)
check(!textSettings.actions[0].sendReturn, "new text after replacing the action starts with automatic Return disabled")
textDefaults.removePersistentDomain(forName: textSuite)
// Insertion positions use original gaps; actions and appearance metadata stay paired.
let insertionSuite = "local.magicwheel.insertion-tests.\(UUID().uuidString)"
let insertionDefaults = UserDefaults(suiteName: insertionSuite)!
let insertionSettings = Settings(defaults: insertionDefaults)
for count in 2...9 {
    let original = (0..<count).map { "text:item-\($0)" }
    for source in 0..<count {
        for boundary in 0...count {
            insertionSettings.slots = original
            for index in 0..<count { insertionSettings.setAppearance(SlotAppearance(name: "name-\(index)", icon: "icon-\(index)", trigger: index % 2 == 0 ? .onEntry : .onRelease), at: index) }
            let styles = insertionSettings.appearances
            let destination = boundary > source ? boundary - 1 : boundary
            let result = insertionSettings.insertSlot(source, before: boundary)
            var expected = Array(0..<count); expected.remove(at: source); expected.insert(source, at: destination)
            check(result == (source == destination ? nil : destination), "insertion returns new selection or no-op")
            check(insertionSettings.slots == expected.map { original[$0] }, "insertion preserves relative order of every other action")
            check(insertionSettings.appearances == expected.map { styles[$0] }, "insertion carries all appearance and trigger metadata")
        }
    }
    for rotation in [0.0, 0.7, -1.5, 2 * .pi - 0.03] {
        for gap in 0..<count {
            let angle = rotation + (Double(gap) - 0.5) * 2 * .pi / Double(count)
            check(wheelInsertionBoundary(WheelVector(x: sin(angle), y: cos(angle)), count: count, rotation: rotation) == gap, "rotated gap detection including last/first seam")
        }
    }
}
check(wheelInsertionBoundary(WheelVector(), count: 4) == nil && wheelInsertionBoundary(WheelVector(x: 1), count: 1) == nil, "center and single-slot wheel cannot reorder")
check(Settings(defaults: insertionDefaults).editingWheel == insertionSettings.editingWheel, "complete insertion survives restart")
for id in ["clearText", "virtualKeyboard"] {
    let action = KeyAction.find(id)
    check(action.enabled && action.operation != nil && !action.canHold, "input operation is bindable but never held")
    check(insertionSettings.updateSlot(0, input: id, textMode: false), "operation saves via preset menu")
    check(Settings(defaults: insertionDefaults).slots[0] == id, "operation binding survives restart")
    check(!["keyboard", "xmark.circle"].filter { $0 == action.glyph }.isEmpty, "operation has a system icon")
}
check(InputActions.canClear(role: kAXTextAreaRole, valueSettable: true, selectionSettable: true), "editable text area accepts clear")
check(!InputActions.canClear(role: kAXListRole, valueSettable: true, selectionSettable: true), "file list rejects clear even with editable attributes")
check(!InputActions.canClear(role: kAXTextFieldRole, valueSettable: false, selectionSettable: false), "noneditable field rejects clear")
// Model an app whose top-level focused-element query is missing, with its
// actual editor 32 levels inside the focused window (as observed in Codex).
struct FocusNode {
    var focused = false
    var editable = false
    var children: [FocusNode] = []
}
let focusedEditor = FocusNode(focused: true, editable: true)
var webEditor = focusedEditor
for _ in 0..<32 { webEditor = FocusNode(children: [webEditor]) }
func findTextFocus(_ root: FocusNode, limit: Int = 2048, depth: Int = 64,
                   shouldContinue: () -> Bool = { true }) -> Bool {
    InputActions.containsFocusedText(in: root, children: { $0.children },
        isFocusedText: { $0.focused && $0.editable }, maximumElements: limit,
        maximumDepth: depth, shouldContinue: shouldContinue)
}
check(findTextFocus(webEditor), "missing application focus falls back to deeply nested focused editor")
check(!findTextFocus(FocusNode(children: [FocusNode(editable: true), FocusNode(focused: true)])), "visible unfocused editor and focused button do not match text scene")
check(!findTextFocus(FocusNode(focused: true)), "focused read-only text does not match")
check(!findTextFocus(webEditor, limit: 10) && !findTextFocus(webEditor, depth: 10), "focus fallback respects node and depth budgets")
check(!findTextFocus(webEditor, shouldContinue: { false }), "expired focus lookup fails closed")
var focusVisits = 0
check(!InputActions.containsFocusedText(in: 0, children: { [$0] }, isFocusedText: { _ in focusVisits += 1; return false }, maximumElements: 20), "cyclic accessibility tree terminates")
check(focusVisits == 20, "cyclic accessibility tree stays within traversal budget")
insertionDefaults.removePersistentDomain(forName: insertionSuite)
// Exercise the actual KeySender encoder without sending keys to the desktop.
var sentKeys: [(CGEvent, CGEventTapLocation)] = []
let routeSender = KeySender(isTrusted: { true }, emit: { sentKeys.append(($0, $1)) })
let commandF1 = RecordedKey(key: 122, flags: CGEventFlags.maskCommand.rawValue | 0x08, label: "⌘F1", modifier: false)
routeSender.tap(KeyAction.find(commandF1.storedValue))
check(sentKeys.count == 2, "Command F1 posts exactly one down/up pair")
check(sentKeys.allSatisfy { $0.1 == .cghidEventTap }, "custom Command F1 reaches global shortcut input layer")
check(sentKeys.map { $0.0.type } == [.keyDown, .keyUp], "function key emits balanced keyboard events")
check(sentKeys.allSatisfy { $0.0.getIntegerValueField(.keyboardEventKeycode) == 122 && $0.0.flags.rawValue == commandF1.flags | CGEventFlags.maskSecondaryFn.rawValue }, "F1 key code and left Command flag survive delivery")
check(sentKeys.allSatisfy { $0.0.getIntegerValueField(.eventSourceUserData) == KeySender.eventTag }, "global shortcut events retain self-event tag")
for code in RecordedKey.functionKeyCodes.sorted() {
    sentKeys = []
    let binding = RecordedKey.capture(key: code, flags: .maskCommand)
    routeSender.tap(KeyAction.find(binding.storedValue))
    check(sentKeys.count == 2 && sentKeys.allSatisfy { $0.0.flags.contains(.maskSecondaryFn) }, "every F1–F20 down/up pair carries intrinsic function flag")
    check(!binding.label.contains("Fn") && binding.flags == CGEventFlags.maskCommand.rawValue, "transport flag does not alter the user's stored Fn binding or label")
}
sentKeys = []
routeSender.tap(KeyAction.find("copy"))
check(sentKeys.count == 2 && sentKeys.allSatisfy { !$0.0.flags.contains(.maskSecondaryFn) }, "ordinary key combos do not gain a function modifier")
for code in [UInt16(0), 49, 122, 120, 111, 90] {
    sentKeys = []
    let action = KeyAction.find(RecordedKey.capture(key: code, flags: [.maskCommand, .maskShift]).storedValue)
    routeSender.hold(action)
    check(sentKeys.count == 1 && sentKeys[0].0.type == .keyDown && sentKeys[0].1 == .cghidEventTap, "held custom shortcut uses global key-down")
    routeSender.release(); routeSender.release()
    check(sentKeys.count == 2 && sentKeys[1].0.type == .keyUp && sentKeys[1].1 == .cghidEventTap, "held custom shortcut releases exactly once on same route")
}
sentKeys = []
routeSender.tap(KeyAction.find("text:你好🙂"))
check(sentKeys.count == 2 && sentKeys.allSatisfy { $0.1 == .cgSessionEventTap }, "Unicode text keeps session delivery")
func unicodeText(_ event: CGEvent) -> String {
    var units = [UniChar](repeating: 0, count: 64), length = 0
    units.withUnsafeMutableBufferPointer {
        event.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &length, unicodeString: $0.baseAddress)
    }
    return String(decoding: units.prefix(length), as: UTF16.self)
}
for phrase in ["你好🙂", String(repeating: "第一行🙂", count: 12) + "\n第二行🙂", "literal text-enter: and text:"] {
    sentKeys = []
    routeSender.tap(KeyAction.find(QuickTextBinding(text: phrase, sendReturn: true).storedValue))
    let textEvents = sentKeys.dropLast(2)
    check(textEvents.filter { $0.0.type == .keyDown }.map { unicodeText($0.0) }.joined() == phrase, "all Unicode chunks arrive before automatic Return")
    check(sentKeys.suffix(2).map { $0.0.type } == [.keyDown, .keyUp] && sentKeys.suffix(2).allSatisfy { $0.0.getIntegerValueField(.keyboardEventKeycode) == 36 }, "automatic Return emits exactly one balanced Return pair after text")
    check(sentKeys.allSatisfy { $0.1 == .cgSessionEventTap && $0.0.flags.isEmpty && $0.0.getIntegerValueField(.eventSourceUserData) == KeySender.eventTag }, "text and automatic Return share ordered delivery without modifiers")
}
sentKeys = []
routeSender.tap(KeyAction.find(QuickTextBinding(text: "", sendReturn: true).storedValue))
check(sentKeys.isEmpty, "empty automatic-send text never presses Return")
routeSender.hold(KeyAction.find(QuickTextBinding(text: "你好", sendReturn: true).storedValue))
check(sentKeys.isEmpty, "automatic-send text cannot be held")
sentKeys = []
routeSender.tap(KeyAction.empty)
check(sentKeys.isEmpty, "empty binding sends no global events")
let untrustedSender = KeySender(isTrusted: { false }, emit: { sentKeys.append(($0, $1)) })
untrustedSender.tap(KeyAction.find(commandF1.storedValue))
check(sentKeys.isEmpty, "untrusted sender does not bypass authorization")
untrustedSender.tap(KeyAction.find(QuickTextBinding(text: "你好", sendReturn: true).storedValue))
check(sentKeys.isEmpty, "untrusted automatic-send text emits no text or Return")
// Shared application groups and portable full-settings files.
let groupSuite = "local.magicwheel.group-tests." + UUID().uuidString
let groupDefaults = UserDefaults(suiteName: groupSuite)!
let grouped = Settings(defaults: groupDefaults)
let memberA = WheelApplication(id: "test.group.a", name: "Editor A", path: "/private/local/A.app")
let memberB = WheelApplication(id: "test.group.b", name: "Editor B", path: "/private/local/B.app")
let memberC = WheelApplication(id: "test.group.c", name: "Browser", path: "/private/local/C.app")
let groupGlobal = grouped.editingWheel
check(grouped.setApplicationGroup(id: nil, name: "Editors", applications: [memberA, memberB]), "create shared group")
let editorGroupID = grouped.selectedApplicationID!
grouped.slots = ["copy", "paste"]; grouped.rotation = 1.2
let sharedWheel = grouped.editingWheel
check(grouped.wheel(for: memberA.id) == sharedWheel && grouped.wheel(for: memberB.id) == sharedWheel, "group members share one edited wheel")
check(grouped.wheel(for: "unknown") == groupGlobal, "unconfigured apps retain global")
check(grouped.addApplication(id: memberB.id, name: memberB.name, path: memberB.path) && grouped.applicationWheels.count == 1, "adding existing member selects shared group")
check(!grouped.setApplicationGroup(id: editorGroupID, name: "Bad", applications: [memberA, memberA]), "duplicate members rejected")
check(!grouped.setApplicationGroup(id: editorGroupID, name: "Bad", applications: []), "empty group rejected")
check(grouped.setApplicationGroup(id: editorGroupID, name: "Writing", applications: [memberA, memberB, memberC]) && grouped.editingWheel == sharedWheel, "editing members preserves wheel and stable ID")
check(grouped.setApplicationGroup(id: nil, name: "Browser only", applications: [memberC]), "reuse app in a new scene")
let browserGroupID = grouped.selectedApplicationID!
grouped.slots = ["escape"]
check(grouped.applicationWheels.count == 2 && grouped.wheel(for: memberA.id) == sharedWheel && grouped.wheel(for: memberB.id) == sharedWheel && grouped.wheel(for: memberC.id) == sharedWheel, "overlapping app scenes preserve first scene precedence")
grouped.selectApplication(editorGroupID)
check(grouped.setApplicationGroup(id: editorGroupID, name: "Editors", applications: [memberA]), "remove member from existing group")
check(grouped.wheel(for: memberB.id) == groupGlobal && grouped.wheel(for: memberA.id) == sharedWheel, "removed member falls back to global")
check(Settings(defaults: groupDefaults).wheel(for: memberA.id) == sharedWheel && Settings(defaults: groupDefaults).applicationWheels.count == 2, "groups survive restart")
grouped.selectApplication(browserGroupID); grouped.removeSelectedApplication()
check(grouped.wheel(for: memberC.id) == groupGlobal && grouped.applicationWheels.count == 1, "removing group restores fallback")
grouped.selectApplication(nil)
let exportedRecorded = RecordedKey.capture(key: 61, flags: .maskAlternate)
grouped.slots = ["return", exportedRecorded.storedValue, "text:Hello\n世界🙂", "text:", systemWorkflow.storedValue, "", "command+f1"]
grouped.appearances = grouped.slots.indices.map { SlotAppearance(name: "Slot \($0)", icon: "keyboard", showName: $0 % 2 == 0, showIcon: $0 % 2 != 0, trigger: .onRelease) }
grouped.rotation = 2.25; grouped.onRelease = true
grouped.addScene(.textInput); grouped.slots = ["clearText", "virtualKeyboard"]
grouped.theme = .glass; grouped.language = .english; grouped.hold = 0.65; grouped.travel = 0.2; grouped.enabled = false
let fullFile = SettingsFile(settings: grouped, launchAtLogin: true)
let fullData = try! fullFile.encoded()
let fullJSON = String(data: fullData, encoding: .utf8)!
check(!fullJSON.contains("/private/local/") && !fullJSON.contains("recorded:") && !fullJSON.contains("mac-shortcut:"), "portable file excludes local paths and exposes structured key/shortcut data")
for retired in ["frosted", "gta", "cyberpunk", "colorful"] {
    var legacyObject = try! JSONSerialization.jsonObject(with: fullData) as! [String: Any]
    var prefs = legacyObject["preferences"] as! [String: Any]
    prefs["theme"] = retired; legacyObject["preferences"] = prefs
    let migratedFile = try! SettingsFile.read(JSONSerialization.data(withJSONObject: legacyObject))
    check(migratedFile.preferences.theme == .glass, "v1 export with retired theme imports as liquid glass")
    check(try! migratedFile.encoded() == fullData, "retired theme migration preserves all other portable settings")
}
var unknownThemeObject = try! JSONSerialization.jsonObject(with: fullData) as! [String: Any]
var unknownThemePreferences = unknownThemeObject["preferences"] as! [String: Any]
unknownThemePreferences["theme"] = "unknown-future-theme"; unknownThemeObject["preferences"] = unknownThemePreferences
do {
    _ = try SettingsFile.read(JSONSerialization.data(withJSONObject: unknownThemeObject))
    check(false, "unknown imported theme must fail validation")
} catch { check(true, "unknown imported theme fails validation") }
let decodedFile = try! SettingsFile.read(fullData)
let importSuite = "local.magicwheel.import-tests." + UUID().uuidString
let importDefaults = UserDefaults(suiteName: importSuite)!
let importedSettings = Settings(defaults: importDefaults)
try! importedSettings.applyImport(decodedFile)
check(importedSettings.wheel(for: nil) == grouped.wheel(for: nil), "full global wheel round trip preserves every action and appearance")
check(importedSettings.wheel(for: memberA.id) == sharedWheel && importedSettings.wheel(for: memberB.id) == grouped.wheel(for: nil), "import retains group routing")
check(importedSettings.wheel(for: memberA.id, scene: .textInput) == grouped.wheel(for: memberA.id, scene: .textInput), "import preserves scene precedence")
check(importedSettings.theme == .glass && importedSettings.language == .english && importedSettings.hold == 0.65 && importedSettings.travel == 0.2 && !importedSettings.enabled && decodedFile.preferences.launchAtLogin, "all portable preferences round trip")
check(importedSettings.selectedTarget == .global, "import resets editing target to global")
check(try! SettingsFile(settings: importedSettings, launchAtLogin: true).encoded() == fullData, "export-import-export is deterministic")
let restartedImport = Settings(defaults: importDefaults)
check(try! SettingsFile(settings: restartedImport, launchAtLogin: true).encoded() == fullData, "all imported settings persist across restart including enable state")
let unchangedImport = fullData
var autoSendFile = decodedFile
autoSendFile.global.slots[2].action = SettingsFile.Action(QuickTextBinding(text: phrase, sendReturn: true).storedValue)
autoSendFile.global.slots[3].action = SettingsFile.Action(QuickTextBinding(text: "", sendReturn: true).storedValue)
let autoSendData = try! autoSendFile.encoded()
let autoSendLibrary = try! SettingsFile.read(autoSendData).validatedLibrary()
check(autoSendLibrary.global.actions[2].sendReturn && autoSendLibrary.global.actions[2].text == phrase, "portable settings preserve text and automatic Return")
check(QuickTextBinding.decode(autoSendLibrary.global.slots[3])?.sendReturn == true && !autoSendLibrary.global.actions[3].enabled, "portable settings preserve disabled empty automatic-send draft")
check(String(data: autoSendData, encoding: .utf8)!.contains("\"sendReturn\" : true"), "portable text action exposes automatic Return as a structured boolean")
func rejectsFile(_ bad: SettingsFile, _ description: String) {
    do { try importedSettings.applyImport(bad); check(false, description) }
    catch { check(try! SettingsFile(settings: importedSettings, launchAtLogin: true).encoded() == unchangedImport, description) }
}
var invalidFile = decodedFile; invalidFile.version = 99
rejectsFile(invalidFile, "unsupported version rejected without mutation")
for version in [1, 2] {
    invalidFile = autoSendFile; invalidFile.version = version
    rejectsFile(invalidFile, "automatic Return cannot be silently downgraded to an older file format")
}
invalidFile = decodedFile; invalidFile.global.slots[0].action.sendReturn = true
rejectsFile(invalidFile, "automatic Return field rejected for non-text actions")
invalidFile = decodedFile; invalidFile.version = 2
check((try! SettingsFile.read(invalidFile.encoded())).version == 2, "v2 files with plain text remain importable")
invalidFile = decodedFile; invalidFile.format = "other-app"
rejectsFile(invalidFile, "wrong format rejected without mutation")
invalidFile = decodedFile; invalidFile.preferences.holdSeconds = 0.01
rejectsFile(invalidFile, "unsafe gesture timing rejected without mutation")
invalidFile = decodedFile; invalidFile.preferences.travel = .nan
rejectsFile(invalidFile, "nonfinite travel rejected without mutation")
invalidFile = decodedFile; invalidFile.applicationGroups.append(invalidFile.applicationGroups[0])
rejectsFile(invalidFile, "duplicate group IDs rejected without mutation")
invalidFile = decodedFile; invalidFile.version = 1
for index in invalidFile.applicationGroups.indices { invalidFile.applicationGroups[index].scenes = nil; invalidFile.applicationGroups[index].matchMode = nil }
var duplicateGroup = invalidFile.applicationGroups[0]; duplicateGroup.id = "another"; invalidFile.applicationGroups.append(duplicateGroup)
rejectsFile(invalidFile, "legacy files retain unambiguous app membership validation")
invalidFile = decodedFile; invalidFile.applicationGroups[0].applications.append(invalidFile.applicationGroups[0].applications[0])
rejectsFile(invalidFile, "duplicate members within one scene rejected")
invalidFile = decodedFile; invalidFile.applicationGroups[0].applications = []
rejectsFile(invalidFile, "empty imported group rejected without mutation")
invalidFile = decodedFile; invalidFile.scenes[0].id = "unknown-scene"
rejectsFile(invalidFile, "unknown scene rejected rather than silently lost")
invalidFile = decodedFile; invalidFile.global.slots[0].action.type = .key
rejectsFile(invalidFile, "missing key payload rejected without mutation")
invalidFile = decodedFile; invalidFile.global.slots[4].appearance.trigger = .whileInside
rejectsFile(invalidFile, "invalid shortcut hold rejected without mutation")
for malformed in [Data("{}".utf8), Data("not JSON".utf8), Data(fullData.prefix(fullData.count / 2)), Data(repeating: 32, count: SettingsFile.maximumBytes + 1)] {
    do { _ = try SettingsFile.read(malformed); check(false, "bad file rejected") }
    catch { check(true, "bad or oversized file rejected") }
}
// Named scenes combine app scope and text focus without exclusive membership.
let ruleSuite = "local.magicwheel.rule-tests." + UUID().uuidString
let ruleDefaults = UserDefaults(suiteName: ruleSuite)!
let rules = Settings(defaults: ruleDefaults)
let ruleGlobal = rules.editingWheel
check(!rules.setWheelRule(id: nil, name: "Empty", applications: [], scenes: [], mode: .all), "empty conditions cannot shadow global")
check(!rules.setWheelRule(id: nil, name: "Duplicate", applications: [memberA, memberA], scenes: [], mode: .all), "duplicate app conditions rejected")
check(!rules.setWheelRule(id: nil, name: "Duplicate", applications: [], scenes: [.textInput, .textInput], mode: .all), "duplicate scene conditions rejected")
check(rules.setWheelRule(id: nil, name: "App", applications: [memberA, memberB], scenes: [], mode: .all), "multi-app named scene created")
let appRuleID = rules.selectedApplicationID!
rules.slots = ["copy"]; let ruleApp = rules.editingWheel
check(rules.setWheelRule(id: nil, name: "General input", applications: [], scenes: [.textInput], mode: .all), "text-only named scene created")
let generalRuleID = rules.selectedApplicationID!
rules.slots = ["paste"]; let generalInput = rules.editingWheel
check(rules.setWheelRule(id: nil, name: "Terminal input", applications: [memberA, memberB], scenes: [.textInput], mode: .all), "combined scene created without moving apps")
let specificRuleID = rules.selectedApplicationID!
rules.slots = ["return"]; rules.rotation = 0.9; let specificInput = rules.editingWheel
check(rules.applicationWheels.first { $0.id == appRuleID }?.members == [memberA, memberB], "overlapping conditions preserve existing membership")
check(rules.needsTextInputScene, "combined and general scenes request runtime text focus detection")
for app in [memberA.id, memberB.id] {
    check(rules.wheel(for: app, scene: .textInput) == specificInput, "app plus text uses specific wheel")
    check(rules.wheel(for: app) == ruleApp, "app without text uses app-only wheel")
}
check(rules.wheel(for: memberC.id, scene: .textInput) == generalInput, "other text inputs use general text wheel")
check(rules.wheel(for: nil, scene: .textInput) == generalInput, "text condition can match without bundle identifier")
check(rules.wheel(for: memberC.id) == ruleGlobal, "unmatched conditions use global")
let ruleFrozen = rules.wheel(for: memberA.id, scene: .textInput)
check(rules.setWheelRule(id: specificRuleID, name: "Renamed", applications: [memberA], scenes: [.textInput], mode: .all) && rules.editingWheel == specificInput, "changing scene name and scope preserves wheel")
rules.slots = []
check(rules.wheel(for: memberA.id, scene: .textInput).slots.isEmpty, "specific empty wheel never falls back")
check(ruleFrozen == specificInput, "opened wheel snapshot remains independent")
rules.slots = ["return"]
check(rules.setWheelRule(id: nil, name: "Either", applications: [memberC], scenes: [.textInput], mode: .any), "either condition scene created")
let eitherRuleID = rules.selectedApplicationID!
rules.slots = ["escape"]; let eitherWheel = rules.editingWheel
check(rules.wheel(for: memberC.id) == eitherWheel, "either rule matches app without text")
check(rules.wheel(for: memberC.id, scene: .textInput) == generalInput, "equally specific scenes use earliest added")
check(rules.wheel(for: memberA.id, scene: .textInput) == specificInput, "specific all rule beats broader either rule")
rules.selectApplication(generalRuleID); rules.removeSelectedApplication()
check(rules.wheel(for: "unknown", scene: .textInput) == eitherWheel, "either rule matches text outside selected apps")
check(rules.wheel(for: "unknown") == ruleGlobal, "either rule rejects neither condition")
let ruleData = try! SettingsFile(settings: rules, launchAtLogin: false).encoded()
let ruleFile = try! SettingsFile.read(ruleData)
check(ruleFile.version == SettingsFile.currentVersion, "condition exports use the current format version")
let reloadedRules = Settings(defaults: ruleDefaults)
check(reloadedRules.wheel(for: memberA.id, scene: .textInput) == specificInput && reloadedRules.wheel(for: memberC.id) == eitherWheel, "overlapping scenes persist across restart")
try! reloadedRules.applyImport(ruleFile)
check(reloadedRules.wheel(for: memberA.id, scene: .textInput) == specificInput && reloadedRules.wheel(for: memberC.id) == eitherWheel, "full file round trip preserves conditions and precedence")
check(try! SettingsFile(settings: reloadedRules, launchAtLogin: false).encoded() == ruleData, "condition file round trip is deterministic")
var legacyFile = decodedFile; legacyFile.version = 1
for index in legacyFile.applicationGroups.indices { legacyFile.applicationGroups[index].scenes = nil; legacyFile.applicationGroups[index].matchMode = nil }
check((try! SettingsFile.read(legacyFile.encoded())).version == 1, "v1 setting files remain importable")
reloadedRules.addScene(.textInput); reloadedRules.slots = ["clearText"]
let legacySceneWheel = reloadedRules.editingWheel
check(reloadedRules.setWheelRule(id: nil, replacingScene: .textInput, name: "Legacy renamed", applications: [memberB], scenes: [.textInput], mode: .all), "legacy text profile can become a named app-scoped scene")
check(reloadedRules.editingWheel == legacySceneWheel && reloadedRules.sceneWheels.isEmpty, "legacy scene conversion retains wheel and removes only source")
let convertedID = reloadedRules.selectedApplicationID!
reloadedRules.removeSelectedApplication()
check(!reloadedRules.applicationWheels.contains { $0.id == convertedID } && reloadedRules.selectedTarget == .global, "named scene deletion returns editor to global")
reloadedRules.selectApplication(eitherRuleID); reloadedRules.removeSelectedApplication()
reloadedRules.selectApplication(specificRuleID); reloadedRules.removeSelectedApplication()
check(!reloadedRules.needsTextInputScene, "text focus queries stop after last text condition removed")
let exampleURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/settings-example.json")
let exampleFile = try! SettingsFile.read(from: exampleURL)
check(exampleFile.applicationGroups.contains { $0.name == "终端输入" && $0.scenes == [.textInput] }, "documented v2 example validates using actual importer")
ruleDefaults.removePersistentDomain(forName: ruleSuite)
// Copy complete wheel contents while preserving the destination scene conditions.
let copySuite = "local.magicwheel.copy-tests." + UUID().uuidString
let copyDefaults = UserDefaults(suiteName: copySuite)!
let copySettings = Settings(defaults: copyDefaults)
let copyGlobal = copySettings.editingWheel
copySettings.setWheelRule(id: nil, name: "Source", applications: [memberA], scenes: [], mode: .all)
let copySource = copySettings.selectedTarget
copySettings.slots = ["copy", "text:Hello", "return"]
copySettings.appearances = [SlotAppearance(name: "Custom", icon: "star", showName: false, showIcon: true, trigger: .onRelease), SlotAppearance(), SlotAppearance()]
copySettings.rotation = 1.7; copySettings.onRelease = true
let copySourceWheel = copySettings.editingWheel
copySettings.setWheelRule(id: nil, name: "Destination", applications: [memberB], scenes: [.textInput], mode: .all)
let copyDestination = copySettings.selectedTarget
let destinationBeforeCopy = copySettings.applicationWheels.first { $0.id == copySettings.selectedApplicationID }!
check(copySettings.copyWheel(from: copySource), "copy wheel from another named scene")
check(copySettings.editingWheel == copySourceWheel, "copy includes all actions, labels, icons, triggers and rotation")
let destinationAfterCopy = copySettings.applicationWheels.first { $0.id == destinationBeforeCopy.id }!
check(destinationAfterCopy.id == destinationBeforeCopy.id && destinationAfterCopy.name == destinationBeforeCopy.name && destinationAfterCopy.members == destinationBeforeCopy.members && destinationAfterCopy.sceneConditions == [.textInput], "copy preserves destination identity and conditions")
copySettings.slots = ["escape"]
check(copySettings.wheel(for: memberA.id) == copySourceWheel, "editing copied wheel leaves source independent")
let modifiedDestination = copySettings.editingWheel
check(!copySettings.copyWheel(from: copyDestination) && copySettings.editingWheel == modifiedDestination, "copy from current scene rejected without mutation")
check(!copySettings.copyWheel(from: .application("missing")) && copySettings.editingWheel == modifiedDestination, "missing copy source rejected without mutation")
check(copySettings.copyWheel(from: .global) && copySettings.editingWheel == copyGlobal, "global wheel can be copied into a scene")
copySettings.addScene(.textInput); copySettings.slots = []; copySettings.rotation = 0.4
let emptySource = copySettings.editingWheel
copySettings.selectTarget(copyDestination)
check(copySettings.copyWheel(from: .scene(.textInput)) && copySettings.editingWheel == emptySource, "legacy and empty wheels can be copied explicitly")
copySettings.selectTarget(.global)
check(copySettings.copyWheel(from: copySource) && copySettings.editingWheel == copySourceWheel, "named scene can seed global wheel")
copySettings.selectTarget(copyDestination)
let destinationTargetBeforeDeletion = copySettings.selectedTarget
let destinationWheelBeforeDeletion = copySettings.editingWheel
check(copySettings.removeProfile(copySource), "dropdown can delete an unselected scene")
check(copySettings.selectedTarget == destinationTargetBeforeDeletion && copySettings.editingWheel == destinationWheelBeforeDeletion, "deleting another scene preserves editing selection and content")
check(!copySettings.profileTargets.contains(copySource) && Settings(defaults: copyDefaults).profileTargets == copySettings.profileTargets, "dropdown deletion persists across restart")
check(!copySettings.removeProfile(.global) && !copySettings.removeProfile(.application("missing")), "global and nonexistent profiles cannot be deleted")
check(copySettings.removeProfile(.scene(.textInput)) && copySettings.selectedTarget == copyDestination, "delete unselected legacy scene without changing editor")
check(copySettings.removeProfile(copyDestination) && copySettings.selectedTarget == .global && copySettings.editingWheel == copySourceWheel, "deleting selected scene restores global editor")
check(copySettings.profileTargets == [.global], "deleting last scene leaves global available")
copyDefaults.removePersistentDomain(forName: copySuite)
if let fixturePath = ProcessInfo.processInfo.environment["MAGICWHEEL_TEST_EXPORT"] {
    try! fullData.write(to: URL(fileURLWithPath: fixturePath), options: .atomic)
}
groupDefaults.removePersistentDomain(forName: groupSuite)
importDefaults.removePersistentDomain(forName: importSuite)
print("PASS: \(checks) gesture, mapping, rotation, settings, placement, and icon search checks")
