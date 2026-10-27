import Foundation
import CoreGraphics
import ScreenCaptureKit
import MirageHost
import MirageCore
import MirageUpdater

/// The update health check's capture probe (DESIGN §3.10, commit): one small frame of the main display through
/// ScreenCaptureKit's screenshot API, or exactly which grant is missing. Never asks for a grant (the host's start already
/// did); without Screen Recording it reports instead of capturing. A capture that fails with the grant present is
/// retried every 10 s: no commit until it works, so a build that cannot capture rolls back at its deadline.
///
/// Every display asleep, as CoreGraphics says (no online display, or all asleep): nothing to capture. The check is deferred
/// ("capture check deferred: display asleep"), health is listener and control, and the probe waits, looking every 30 s
/// without waking anything (no IOPMAssertionDeclareUserActivity here), for a display to wake; then it tries up to
/// `UpdateHealth.AfterWake.attempts` times and its result goes into the update's record. With a display awake,
/// ScreenCaptureKit listing none is a failure, not a reason to defer.
func probeCaptureForHealth(screen: Bool, ax: Bool, health: HostHealth) {
    let axNote = ax ? "accessibility granted" : "accessibility missing (\(PrivacyPane.accessibility()))"
    guard screen else { health.passed(.capture("Screen Recording missing (\(PrivacyPane.screenRecording), no frame), \(axNote)")); return }
    Task.detached {
        var deferred = false
        var afterWake = UpdateHealth.AfterWake()
        while true {
            if deferred, allDisplaysAsleep() { afterWake.asleepAgain(); try? await Task.sleep(for: .seconds(30)); continue }
            do {
                let detail = try await captureOnce(axNote: axNote)
                if deferred { health.capturedAfterWake(detail, ok: true) } else { health.passed(.capture(detail)) }
                return
            } catch {
                switch UpdateHealth.onCaptureFailure(displaysAsleep: allDisplaysAsleep()) {
                case .deferAsleep:
                    if !deferred {
                        log("update health: capture check deferred: display asleep (\(error))")
                        health.passed(.captureDeferred("display asleep"))
                        deferred = true
                    }
                    afterWake.asleepAgain()
                    try? await Task.sleep(for: .seconds(30))
                case .retry:
                    if deferred {
                        // Awake, and it fails: a few tries, then recorded (a committed build stays; a viewer may roll it back).
                        if afterWake.failed() { health.capturedAfterWake("\(error)", ok: false); return }
                        log("update health: capture after wake failed (\(error)); try \(afterWake.failures + 1) of \(UpdateHealth.AfterWake.attempts) in 10 s")
                        try? await Task.sleep(for: .seconds(10))
                        continue
                    }
                    log("update health: capture probe failed (\(error)); retrying in 10 s")
                    health.waiting(for: "a screen capture (\(error))")
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }
}

private func captureOnce(axNote: String) async throws -> String {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else { throw ProbeError.noDisplay }
    let cfg = SCStreamConfiguration()
    cfg.width = 64; cfg.height = 36; cfg.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
    return "frame \(image.width)×\(image.height) of display \(display.displayID), \(axNote)"
}

/// Every online display asleep (or none online). Reads state only: wakes nothing.
func allDisplaysAsleep() -> Bool {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return false }   // an error is not "asleep": keep checking
    guard count > 0 else { return true }   // no online display (headless): nothing to capture
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
}

enum ProbeError: Error { case noDisplay }
