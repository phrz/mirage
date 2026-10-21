import XCTest
import AppKit
@testable import mirage_viewer
@testable import MirageCore

/// The Mac viewer's defaults (DESIGN §3.9 parity with iOS): automatic bitrate with no 800 cap left over from older builds,
/// no stats overlay unless turned on (then remembered), and the toolbar's toggles following that state.
@MainActor
final class ViewerSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "mirage-viewer-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    // MARK: Bitrate migration

    func testFreshInstallIsAutomaticWithoutStats() {
        let prefs = ViewerPreferences(defaults: defaults)
        XCTAssertEqual(prefs.bitrateKbps, 0, "automatic")
        let controls = ViewerControls(defaults: defaults)
        XCTAssertFalse(controls.showStats, "no debug overlay by default")
        XCTAssertTrue(controls.captureShortcuts, "⌘-shortcuts go to the remote Mac, as before")
        XCTAssertFalse(ViewerModel(bitrateKbps: 0, pixelFactor: 1).showStats)
        XCTAssertEqual(defaults.integer(forKey: ViewerSettings.versionKey), ViewerSettings.version)
    }

    func testOlderBuildsBitrate800BecomesAutomatic() {
        defaults.set(800, forKey: ViewerSettings.legacyBitrateKey)        // older builds' key and compiled-in default
        let prefs = ViewerPreferences(defaults: defaults)
        XCTAssertEqual(prefs.bitrateKbps, 0)
        XCTAssertNil(defaults.object(forKey: ViewerSettings.legacyBitrateKey), "the old key is gone")
    }

    func testStoredCapOf800BecomesAutomatic() {
        defaults.set(800, forKey: ViewerSettings.bitrateKey)
        XCTAssertEqual(ViewerPreferences(defaults: defaults).bitrateKbps, 0)
        XCTAssertNil(defaults.object(forKey: ViewerSettings.bitrateKey))
    }

    func testOtherCapsAreKept() {
        defaults.set(2_000, forKey: ViewerSettings.bitrateKey)
        defaults.set(800, forKey: ViewerSettings.legacyBitrateKey)
        XCTAssertEqual(ViewerPreferences(defaults: defaults).bitrateKbps, 2_000, "a real choice survives")
    }

    func testA800CapChosenAfterTheMigrationIsKept() {
        let prefs = ViewerPreferences(defaults: defaults)   // migrates
        prefs.bitrateKbps = 800                              // the person picks 800 in Settings
        XCTAssertEqual(ViewerPreferences(defaults: defaults).bitrateKbps, 800, "migrates once, not at every launch")
        prefs.bitrateKbps = 0
        XCTAssertNil(defaults.object(forKey: ViewerSettings.bitrateKey), "automatic is stored as no cap")
    }

    // MARK: Controls (toolbar, View menu, Settings)

    func testStatsAndShortcutsAreRemembered() {
        let c = ViewerControls(defaults: defaults)
        let model = ViewerModel(bitrateKbps: 0, pixelFactor: 1)
        c.model = model
        XCTAssertFalse(model.showStats)
        c.toggleStats()
        XCTAssertTrue(c.showStats); XCTAssertTrue(model.showStats, "the connected picture follows")
        c.toggleCaptureShortcuts()
        XCTAssertFalse(c.captureShortcuts)
        // The next launch starts as left.
        let next = ViewerControls(defaults: defaults)
        XCTAssertTrue(next.showStats)
        XCTAssertFalse(next.captureShortcuts)
        let m2 = ViewerModel(bitrateKbps: 0, pixelFactor: 1)
        next.model = m2
        XCTAssertTrue(m2.showStats, "a new connection opens with the overlay as it was left")
    }

    func testScriptedRunsRememberNothing() {
        let c = ViewerControls(defaults: defaults, remember: false)
        c.setShowStats(true)
        c.setCaptureShortcuts(false)
        XCTAssertTrue(c.showStats)
        let next = ViewerControls(defaults: defaults)
        XCTAssertFalse(next.showStats)
        XCTAssertTrue(next.captureShortcuts)
    }

    func testToolbarItemsFollowTheControls() throws {
        let c = ViewerControls(defaults: defaults)
        var settings = 0, disconnects = 0
        c.onSettings = { settings += 1 }
        c.onDisconnect = { disconnects += 1 }
        let t = ViewerToolbar(controls: c)
        let ids = t.toolbarDefaultItemIdentifiers(t.toolbar)
        XCTAssertEqual(ids, [.flexibleSpace, ViewerToolbar.shortcuts, ViewerToolbar.stats, ViewerToolbar.settings, ViewerToolbar.disconnect],
                       "iOS's bar: keyboard (here ⌘-shortcuts), stats, settings, disconnect")
        var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
        for id in ids.dropFirst() { items[id] = t.toolbar(t.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true) }
        for (id, item) in items {
            XCTAssertNotNil(item.image ?? (item.view as? NSButton)?.image, "\(id): an SF Symbol")
            XCTAssertFalse(item.label.isEmpty)
        }
        let stats = try XCTUnwrap(t.buttons[ViewerToolbar.stats]), shortcuts = try XCTUnwrap(t.buttons[ViewerToolbar.shortcuts])
        XCTAssertEqual(stats.state, .off, "stats hidden by default")
        XCTAssertEqual(shortcuts.state, .on)
        stats.performClick(nil)
        XCTAssertTrue(c.showStats); XCTAssertEqual(stats.state, .on)
        shortcuts.performClick(nil)
        XCTAssertFalse(c.captureShortcuts); XCTAssertEqual(shortcuts.state, .off)
        // A change from elsewhere (View › Show Stats, ⌃⌥⌘S, Settings) shows in the toolbar.
        c.toggleStats()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(stats.state, .off)
        t.openSettings(); t.disconnect()
        XCTAssertEqual(settings, 1); XCTAssertEqual(disconnects, 1)
    }

    // MARK: Connect window

    func testRecentHostsComeFirst() {
        let known = [(alias: "alpha", name: "Alpha"), (alias: "mac-daddy", name: "mac-daddy"), (alias: "zeta", name: "Zeta")]
        let hosts = ConnectView.hosts(known: known, recent: ["zeta", "gone", "mac-daddy"])
        XCTAssertEqual(hosts.map(\.alias), ["zeta", "mac-daddy", "alpha"], "most recent first, then the other paired Macs; unpaired ones are not listed")
        ViewerSettings.noteConnected("alpha", defaults)
        ViewerSettings.noteConnected("zeta", defaults)
        ViewerSettings.noteConnected("alpha", defaults)
        XCTAssertEqual(ViewerSettings.recentHosts(defaults), ["alpha", "zeta"])
        XCTAssertEqual(defaults.string(forKey: "lastHost"), "alpha")
    }
}
