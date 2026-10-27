import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import MirageCore

/// "Stay Reachable" (DESIGN §3.12, phrz 2026-10-27): while the host setting is on, miraged keeps the Mac from idle system
/// sleep so a viewer can connect. A `PreventUserIdleSystemSleep` assertion only, never a display one: the display still
/// sleeps (and the Mac locks after it, if set to), and closing a laptop's lid still sleeps it. On a Mac with a battery it is
/// held only on the power adapter, as macOS's own "Prevent automatic sleeping on power adapter when the display is off".
public final class StayReachable: @unchecked Sendable {
    public static let shared = StayReachable()

    /// Hold the assertion: the setting on, and the Mac on the power adapter (or reporting no power source: a desktop).
    public static func shouldHold(enabled: Bool, powerSource: String?) -> Bool {
        enabled && (powerSource == nil || powerSource == kIOPMACPowerKey)
    }

    private var enabled = false
    private var started = false
    private var assertion: IOPMAssertionID = 0
    private var source: CFRunLoopSource?
    private var log: @Sendable (String) -> Void = { _ in }

    /// The login-item host only (never a test instance): watches the power source from here on.
    public func start(enabled: Bool, log: @escaping @Sendable (String) -> Void) {
        DispatchQueue.main.async {
            self.log = log; self.started = true
            if self.source == nil, let s = IOPSNotificationCreateRunLoopSource({ _ in StayReachable.shared.powerChanged() }, nil)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
                self.source = s
            }
            self.enabled = enabled
            self.apply()
        }
    }
    /// The setting changed (the Mirage menu: at once), or was read again (a session beginning or ending, for a hand edit of
    /// the file). Nothing before `start`: a test instance never holds it.
    public func set(_ on: Bool) { DispatchQueue.main.async { guard self.started, on != self.enabled else { return }; self.enabled = on; self.apply() } }
    private func powerChanged() { DispatchQueue.main.async { self.apply() } }

    private func apply() {
        let power = Self.providingPowerSource()
        let want = Self.shouldHold(enabled: enabled, powerSource: power)
        if want, assertion == 0 {
            let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Mirage: stay reachable for viewers" as CFString, &assertion)
            log(r == kIOReturnSuccess ? "stay reachable: preventing idle system sleep (\(power ?? "no power source reported"); the display still sleeps)"
                                      : "stay reachable: the sleep assertion failed (\(r))")
            if r != kIOReturnSuccess { assertion = 0 }
        } else if !want, assertion != 0 {
            IOPMAssertionRelease(assertion); assertion = 0
            log("stay reachable: idle system sleep allowed again (\(enabled ? "on \(power ?? "?")" : "the setting is off"))")
        }
    }
    static func providingPowerSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    }
}
