import SwiftUI
import MetalKit

/// AppKit owns the window (no SwiftUI scene restoration), so every launch opens exactly one window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = LabSettings()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Reveal Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Reveal Lab"
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 1100, height: 720)
        window.contentView = NSHostingView(rootView: ContentView(s: settings))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

@main
enum RevealLabMain {
    static func main() {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

struct ContentView: View {
    @ObservedObject var s: LabSettings
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Picker("", selection: $s.tab) {
                        ForEach(MockTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    Spacer()
                    Picker("", selection: $s.style) {
                        ForEach(FillStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 480)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                MetalContainer(settings: s)
            }
            Divider()
            ControlPanel(s: s).frame(width: 300)
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(format(value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            if let step { Slider(value: $value, in: range, step: step).controlSize(.small) }
            else { Slider(value: $value, in: range).controlSize(.small) }
        }
    }
}

struct ControlPanel: View {
    @ObservedObject var s: LabSettings
    func has(_ kp: PartialKeyPath<FillParams>) -> Bool { s.style.knobs.contains(kp) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Simulated host") {
                    VStack(spacing: 6) {
                        SliderRow(title: "Latency", value: $s.latencyMs, range: 0...1000, step: 10) { "\(Int($0)) ms" }
                        SliderRow(title: "Bandwidth", value: $s.bandwidthRows, range: 100...20000, step: 100) { "\(Int($0)) rows/s" }
                        SliderRow(title: "Host margin", value: $s.marginPt, range: 0...600, step: 10) { "\(Int($0)) pt" }
                        SliderRow(title: "Host frame interval", value: $s.hostFrameMs, range: 0...250, step: 5) { $0 == 0 ? "continuous" : "\(Int($0)) ms" }
                    }.padding(4)
                }
                GroupBox(s.style.subtitle) {
                    VStack(spacing: 6) {
                        if has(\.blurOffset) { SliderRow(title: "Blur radius (offset)", value: s.binding(\.blurOffset), range: 0.25...6) }
                        if has(\.passes) { SliderRow(title: "Kawase passes", value: s.binding(\.passes), range: 1...6, step: 1) { "\(Int($0))" } }
                        if has(\.divisor) { SliderRow(title: "Resolution divisor", value: s.binding(\.divisor), range: 1...8, step: 1) { "1/\(Int($0))" } }
                        if has(\.smearRows) { SliderRow(title: "Smear rows (N)", value: s.binding(\.smearRows), range: 2...200, step: 1) { "\(Int($0)) pt" } }
                        if has(\.tileRows) { SliderRow(title: "Tile rows repeated", value: s.binding(\.tileRows), range: 16...300, step: 1) { "\(Int($0)) pt" } }
                        if has(\.tileShift) { SliderRow(title: "Repeat offset", value: s.binding(\.tileShift), range: 0...60, step: 1) { "\(Int($0)) pt" } }
                        if has(\.feather) { SliderRow(title: "Edge feather (outside)", value: s.binding(\.feather), range: 0...80, step: 1) { "\(Int($0)) pt" } }
                        if has(\.innerFeather) { SliderRow(title: "Feather inside known edge", value: s.binding(\.innerFeather), range: 0...48, step: 1) { "\(Int($0)) pt" } }
                        if has(\.ext) { SliderRow(title: "Extension length", value: s.binding(\.ext), range: 20...1000, step: 10) { "\(Int($0)) pt" } }
                        if has(\.vignette) { SliderRow(title: "Vignette", value: s.binding(\.vignette), range: 0...1) }
                        if has(\.desat) { SliderRow(title: "Desaturation", value: s.binding(\.desat), range: 0...1) }
                        if has(\.grain) { SliderRow(title: "Noise / grain", value: s.binding(\.grain), range: 0...1) }
                        if has(\.tint) { SliderRow(title: "Frosted tint", value: s.binding(\.tint), range: 0...1) }
                        if has(\.rim) { SliderRow(title: "Glass rim", value: s.binding(\.rim), range: 0...1) }
                        if has(\.warpAmp) { SliderRow(title: "Blob motion amplitude", value: s.binding(\.warpAmp), range: 0...40, step: 1) { $0 == 0 ? "off" : "\(Int($0)) pt" } }
                        if has(\.warpSpeed) { SliderRow(title: "Blob motion speed", value: s.binding(\.warpSpeed), range: 0...2) }
                        SliderRow(title: "Crossfade", value: s.binding(\.crossfadeMs), range: 0...1000, step: 10) { "\(Int($0)) ms" }
                    }.padding(4)
                }
                HStack {
                    Button("Replay") { s.replay() }.keyboardShortcut("r", modifiers: [])
                    Button("Top") { s.resetToTop() }
                    Spacer()
                    Toggle("Freeze", isOn: $s.frozen).toggleStyle(.checkbox)
                }
                Toggle("Show known/unknown boundary", isOn: $s.showBoundary).toggleStyle(.checkbox).font(.system(size: 11))
                if s.showBoundary {
                    Text("green: edge of delivered content · yellow tint: rows still crossfading in · blue dashes: host-confirmed viewport · pink: unknown (fill)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                GroupBox("GPU (this Mac)") {
                    VStack(alignment: .leading, spacing: 3) {
                        stat("Fill pass", String(format: "%.3f ms avg · p95 %.3f", s.fillMs, s.fillP95))
                        stat("Fill dispatches", "\(s.dispatches)")
                        stat("Composite", String(format: "%.3f ms avg", s.compositeMs))
                        stat("iPhone 15 est.", String(format: "%.3f ms (budget 0.5)", s.iphoneEstimate))
                        stat("Unknown rows", String(format: "%.0f%% of view", s.unknownFraction * 100))
                        Text("\(s.drawablePx). Fill = edge average + base + blur/pyramid + temporal blend (one command buffer); composite = the full-screen pass that also shades the fill. The iPhone estimate scales fill time by \(s.gpuCores)/5 GPU cores and by iPhone 15 pixels (1179×2556) over this view's; it is rough, and wrong where fixed per-dispatch cost dominates. Light loads run at low GPU clocks, so these are pessimistic.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            .padding(10)
        }
    }
    func stat(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.system(size: 11)); Spacer(); Text(v).font(.system(size: 11).monospacedDigit()) }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class LabContainerView: NSView {
    let mtk: MTKView
    let scroll: NSScrollView
    var onWindow: ((NSWindow) -> Void)?
    init(device: MTLDevice) {
        mtk = MTKView(frame: .zero, device: device)
        scroll = NSScrollView(frame: .zero)
        super.init(frame: .zero)
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtk.preferredFramesPerSecond = 120
        mtk.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed
        scroll.autoresizingMask = [.width, .height]
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: ContentGeometry.heightPt))
        scroll.documentView = doc
        addSubview(mtk)
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); mtk.frame = bounds; scroll.frame = bounds }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let w = window { onWindow?(w) } }
}

struct MetalContainer: NSViewRepresentable {
    let settings: LabSettings
    func makeCoordinator() -> Renderer { Renderer(settings: settings) }
    func makeNSView(context: Context) -> LabContainerView {
        let r = context.coordinator
        let v = LabContainerView(device: r.device)
        v.mtk.delegate = r
        r.scrollView = v.scroll
        v.onWindow = { w in
            let id = w.windowNumber
            print("WINDOW_ID \(id)"); fflush(stdout)
            if let f = settings.winIdFile {
                // "<windowID> x,y,w,h" with the rect in top-left-origin screen points (for screencapture -R).
                let fr = w.frame
                let primaryH = NSScreen.screens.first?.frame.height ?? fr.maxY
                let rect = "\(Int(fr.minX)),\(Int(primaryH - fr.maxY)),\(Int(fr.width)),\(Int(fr.height))"
                try? "\(id) \(rect)\n".write(toFile: f, atomically: true, encoding: .utf8)
            }
        }
        return v
    }
    func updateNSView(_ nsView: LabContainerView, context: Context) {}
}
