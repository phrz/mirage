import AppKit
import Combine

/// The connected window's toolbar: unified with the title bar, SF Symbols, the same actions as iOS's glass button bar
/// (there: keyboard, touch mode, stats, settings, disconnect; here the keyboard's counterpart is where ⌘-shortcuts go,
/// and there is no touch mode). In full screen it hides with the menu bar (`autoHideToolbar`), as other Mac apps' do.
@MainActor
final class ViewerToolbar: NSObject, NSToolbarDelegate {
    static let shortcuts = NSToolbarItem.Identifier("com.paulherz.mirage.shortcuts")
    static let stats = NSToolbarItem.Identifier("com.paulherz.mirage.stats")
    static let settings = NSToolbarItem.Identifier("com.paulherz.mirage.settings")
    static let disconnect = NSToolbarItem.Identifier("com.paulherz.mirage.disconnect")

    let controls: ViewerControls
    let toolbar = NSToolbar(identifier: "com.paulherz.mirage.viewer")
    /// The toggles' buttons (their state follows the controls).
    private(set) var buttons: [NSToolbarItem.Identifier: NSButton] = [:]
    private var sink: AnyCancellable?

    init(controls: ViewerControls) {
        self.controls = controls
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        sink = controls.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.shortcuts, Self.stats, Self.settings, Self.disconnect]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.shortcuts:
            toggle(item, symbol: "command", label: "Shortcuts", tip: "Send Keyboard Shortcuts to the Mac: ⌘-shortcuts typed over the picture go to the remote Mac, not to Mirage", action: #selector(toggleShortcuts))
        case Self.stats:
            toggle(item, symbol: "chart.bar.xaxis", label: "Stats", tip: "Show Stats (⌃⌥⌘S)", action: #selector(toggleStats))
        case Self.settings:
            plain(item, symbol: "gearshape", label: "Settings", tip: "Settings (⌘,)", action: #selector(openSettings))
        case Self.disconnect:
            plain(item, symbol: "xmark", label: "Disconnect", tip: "Disconnect from this Mac", action: #selector(disconnect))
        default:
            return nil
        }
        refresh()
        return item
    }

    private func plain(_ item: NSToolbarItem, symbol: String, label: String, tip: String, action: Selector) {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label; item.paletteLabel = label; item.toolTip = tip
        item.target = self; item.action = action
        item.isBordered = true
    }

    /// An on/off item: a toolbar button that stays pressed (tinted) while on.
    private func toggle(_ item: NSToolbarItem, symbol: String, label: String, tip: String, action: Selector) {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        b.bezelStyle = .toolbar
        b.setButtonType(.pushOnPushOff)
        b.toolTip = tip
        b.setAccessibilityLabel(label)
        item.view = b
        item.label = label; item.paletteLabel = label; item.toolTip = tip
        buttons[item.itemIdentifier] = b
    }

    /// The toggles show the controls' state.
    func refresh() {
        buttons[Self.shortcuts]?.state = controls.captureShortcuts ? .on : .off
        buttons[Self.stats]?.state = controls.showStats ? .on : .off
    }

    @objc func toggleShortcuts() { controls.toggleCaptureShortcuts(); refresh() }
    @objc func toggleStats() { controls.toggleStats(); refresh() }
    @objc func openSettings() { controls.openSettings() }
    @objc func disconnect() { controls.disconnect() }
}
