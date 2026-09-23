import Foundation
import IOKit.ps
import IOKit.pwr_mgt

public struct PowerInfo: Equatable, Sendable {
    public var hasBattery: Bool
    public var onACPower: Bool
    public var batteryPercent: Int?

    public init(hasBattery: Bool, onACPower: Bool, batteryPercent: Int? = nil) {
        self.hasBattery = hasBattery
        self.onACPower = onACPower
        self.batteryPercent = batteryPercent
    }

    /// Reads the power source from IOKit. A Mac without a battery is always on AC.
    public static func current() -> PowerInfo {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerInfo(hasBattery: false, onACPower: true)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        var hasBattery = false
        var percent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                hasBattery = true
                if let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = Int((Double(current) / Double(max) * 100).rounded())
                }
            }
        }
        return PowerInfo(hasBattery: hasBattery, onACPower: !hasBattery || providing == kIOPMACPowerKey, batteryPercent: percent)
    }
}

/// Holding and releasing "don't idle-sleep". A protocol so the agent can be tested without touching power management.
public protocol PowerAsserting: AnyObject {
    var isHeld: Bool { get }
    @discardableResult func hold(reason: String) -> Bool
    func release()
}

/// A `PreventUserIdleSystemSleep` assertion, the same kind `caffeinate -i` takes. The display may still sleep;
/// the system won't. macOS drops the assertion automatically if this process exits.
public final class PowerAssertion: PowerAsserting {
    private var id = IOPMAssertionID(0)
    public private(set) var isHeld = false

    public init() {}

    deinit {
        release()
    }

    @discardableResult
    public func hold(reason: String) -> Bool {
        if isHeld { return true }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        isHeld = result == kIOReturnSuccess
        return isHeld
    }

    public func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        isHeld = false
    }
}
