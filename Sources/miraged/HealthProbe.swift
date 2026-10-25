import Foundation
import ScreenCaptureKit
import MirageHost
import MirageUpdater

/// The update health check's capture probe (DESIGN §3.10, commit): one small frame of the main display through
/// ScreenCaptureKit's screenshot API, or exactly which grant is missing. Never asks for a grant (the host's start already
/// did); without Screen Recording it reports instead of capturing. A capture that fails with the grant present is
/// retried every 10 s: no commit until it works, so a build that cannot capture rolls back at its deadline.
func probeCaptureForHealth(screen: Bool, ax: Bool, health: HostHealth) {
    let axNote = ax ? "accessibility granted" : "Accessibility missing"
    guard screen else { health.passed(.capture("Screen Recording missing (no frame), \(axNote)")); return }
    Task.detached {
        while true {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw ProbeError.noDisplay }
                let cfg = SCStreamConfiguration()
                cfg.width = 64; cfg.height = 36; cfg.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
                health.passed(.capture("frame \(image.width)×\(image.height) of display \(display.displayID), \(axNote)"))
                return
            } catch {
                log("update health: capture probe failed (\(error)); retrying in 10 s")
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

enum ProbeError: Error { case noDisplay }
