import Foundation

struct Contact {
    var id: Int
    var x: Double
    var y: Double
}
struct WheelVector: Equatable {
    var x: Double = 0
    var y: Double = 0
    var length: Double { hypot(x, y) }
}
enum GestureEffect: Equatable {
    case show
    case move(WheelVector)
    case finish
    case cancel
}
// Pure state machine; gestures on different hardware never share a candidate.
final class GestureCore {
    // A brief two-finger tap must never qualify as a hold, even with old settings.
    static let minimumHold = 0.30
    var fingerCount = 2 { didSet { if fingerCount != oldValue { reset() } } }
    var holdDuration = 0.45
    var movementTolerance = 0.018
    var travel = 0.14
    private(set) var active = false
    private var device: UInt64?
    private var initial: [Contact] = []
    private var anchor = WheelVector()
    private var start: Double = 0
    private var blocked = false
    private var activeTravel = 0.14

    private func centroid(_ contacts: [Contact]) -> WheelVector {
        WheelVector(x: contacts.map(\.x).reduce(0, +) / Double(contacts.count),
                    y: contacts.map(\.y).reduce(0, +) / Double(contacts.count))
    }
    func reset() {
        active = false; device = nil; initial = []; blocked = false
    }
    func blockUntilLift() {
        active = false; blocked = true
    }
    func accepts(device source: UInt64) -> Bool { device == nil || device == source }
    func consume(device source: UInt64, contacts: [Contact], time: Double) -> [GestureEffect] {
        guard accepts(device: source) else { return [] }
        if contacts.isEmpty {
            let wasActive = active
            reset()
            return wasActive ? [.finish] : []
        }
        if active {
            // Track only the fingers that opened the wheel. Resting another
            // finger must neither dismiss it nor shift its selection.
            let held = initial.compactMap { original in contacts.first { $0.id == original.id } }
            guard held.count == initial.count else {
                active = false; blocked = true
                return [.finish]
            }
            let current = centroid(held)
            return [.move(WheelVector(x: (current.x - anchor.x) / activeTravel,
                                      y: (current.y - anchor.y) / activeTravel))]
        }
        if contacts.count != fingerCount {
            if device != nil { blocked = true }
            return []
        }
        let sorted = contacts.sorted { $0.id < $1.id }
        if device == nil {
            device = source; initial = sorted; start = time
            anchor = centroid(sorted)
            return []
        }
        guard !blocked else { return [] }
        if zip(initial, sorted).contains(where: { $0.id != $1.id }) {
            let wasActive = active; active = false; blocked = true
            return wasActive ? [.cancel] : []
        }
        let current = centroid(sorted)
        if zip(initial, sorted).contains(where: { hypot($1.x - $0.x, $1.y - $0.y) > movementTolerance }) {
            blocked = true; return []
        }
        if time - start >= max(Self.minimumHold, holdDuration) {
            active = true; anchor = current
            activeTravel = travel.isFinite && travel > 0 ? travel : 0.14
            return [.show, .move(WheelVector())]
        }
        return []
    }
}

// Continuous displacement; crossing a sector's dead zone must not teleport
// the indicator from the center to the rim. Clamp only at the outer edge.
func wheelIndicatorOffset(_ vector: WheelVector, radius: Double = 120, limit: Double = 148) -> WheelVector {
    guard vector.x.isFinite, vector.y.isFinite else { return WheelVector() }
    let distance = vector.length * radius
    let gain = distance > limit ? limit / vector.length : radius
    return WheelVector(x: vector.x * gain, y: vector.y * gain)
}
// Equal sectors, starting at the rotated top and proceeding clockwise.
func normalizedAngle(_ angle: Double) -> Double {
    let full = 2 * Double.pi
    let value = angle.truncatingRemainder(dividingBy: full)
    return value < 0 ? value + full : value
}
func wheelSector(_ v: WheelVector, count: Int = 8, rotation: Double = 0, previous: Int? = nil) -> Int? {
    guard count > 0, v.length >= 0.27 else { return nil }
    let step = 2 * Double.pi / Double(count)
    let angle = normalizedAngle(atan2(v.x, v.y) - rotation)
    if let previous, (0..<count).contains(previous) {
        var delta = abs(angle - Double(previous) * step)
        delta = min(delta, 2 * .pi - delta)
        if delta < step / 2 + min(0.07, step * 0.15) { return previous }
    }
    return Int(floor((angle + step / 2) / step)) % count
}

// AppKit screen coordinates: the window center stays exactly on the cursor.
func wheelOrigin(cursor: CGPoint, size: CGSize) -> CGPoint {
    CGPoint(x: cursor.x - size.width / 2, y: cursor.y - size.height / 2)
}

// Closest gap, numbered by the slot immediately clockwise from it.
func wheelInsertionBoundary(_ v: WheelVector, count: Int, rotation: Double = 0) -> Int? {
    guard count > 1, v.length >= 0.27, v.x.isFinite, v.y.isFinite, rotation.isFinite else { return nil }
    let step = 2 * Double.pi / Double(count)
    let angle = normalizedAngle(atan2(v.x, v.y) - rotation)
    return (Int(floor(angle / step)) + 1) % count
}
