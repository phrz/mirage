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

    private func known(_ name: String, model: String? = nil, family: String? = nil, last: Date? = nil) -> Store.KnownHost {
        Store.KnownHost(hostID: name, hostName: name, publicKey: Data(), endpoint: name, pairedAt: Date(timeIntervalSince1970: 0), model: model, family: family, lastConnected: last)
    }

    func testRecentHostsComeFirst() {
        let known = ["alpha": known("Alpha"), "mac-daddy": known("mac-daddy"), "zeta": known("Zeta")]
        let hosts = ConnectList.hosts(known: known, recent: ["zeta", "gone", "mac-daddy"])
        XCTAssertEqual(hosts.map(\.alias), ["zeta", "mac-daddy", "alpha"], "most recent first, then the other paired Macs; unpaired ones are not listed")
        ViewerSettings.noteConnected("alpha", defaults)
        ViewerSettings.noteConnected("zeta", defaults)
        ViewerSettings.noteConnected("alpha", defaults)
        XCTAssertEqual(ViewerSettings.recentHosts(defaults), ["alpha", "zeta"])
        XCTAssertEqual(defaults.string(forKey: "lastHost"), "alpha")
    }

    func testOrderAndIcons() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let known = ["100.80.102.7": known("mac-daddy", model: "Mac15,14", last: last), "b": known("Bravo", family: "macBookAir"), "a": known("Zulu", model: "Mac99,1")]
        let hosts = ConnectList.hosts(known: known, recent: [])
        XCTAssertEqual(hosts.map(\.title), ["mac-daddy", "Bravo", "Zulu"], "the last connected to first, then by the host's name (not the alias)")
        XCTAssertEqual(hosts.map(\.family), [.macStudio, .macBookAir, .mac], "the host's own family, else from its model; an unknown Apple silicon model is a Mac")
        XCTAssertEqual(hosts[0].lastConnected, last)
        XCTAssertEqual(ConnectList.hosts(known: known, recent: ["a"]).map(\.title), ["Zulu", "mac-daddy", "Bravo"], "this device's recent list comes first")
    }

    func testEmptyListAndInitialSelection() {
        XCTAssertTrue(ConnectList.hosts(known: [:], recent: ["gone"]).isEmpty, "no paired Macs: the empty state")
        XCTAssertNil(ConnectList.initialSelection([], lastHost: "mac-daddy"))
        let hosts = ConnectList.hosts(known: ["a": known("A"), "b": known("B")], recent: ["b"])
        XCTAssertEqual(ConnectList.initialSelection(hosts, lastHost: "a"), "a", "the Mac connected to last")
        XCTAssertEqual(ConnectList.initialSelection(hosts, lastHost: "unpaired.local"), "b", "else the first row")
        XCTAssertEqual(ConnectList.initialSelection(hosts, lastHost: nil), "b")
    }

    func testRowDetail() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let en = Locale(identifier: "en_US")
        XCTAssertNil(PairedHost(alias: "mac-daddy", name: "mac-daddy").detail(now: now, locale: en), "nothing to add to the name")
        XCTAssertNil(PairedHost(alias: "mac-daddy.local", name: "mac-daddy").detail(now: now, locale: en))
        XCTAssertEqual(PairedHost(alias: "100.80.102.7", name: "mac-daddy").detail(now: now, locale: en), "100.80.102.7")
        XCTAssertEqual(PairedHost(alias: "m", name: "M", lastConnected: now.addingTimeInterval(-2 * 86_400)).detail(now: now, locale: en), "Connected 2 days ago")
        XCTAssertEqual(PairedHost(alias: "x", name: "x", lastConnected: now.addingTimeInterval(-5)).detail(now: now, locale: en), "Connected just now")
        XCTAssertEqual(PairedHost(alias: "", name: "").title, "")
        XCTAssertEqual(PairedHost(alias: "10.0.0.2", name: "").title, "10.0.0.2", "a host with no name shows its address")
    }

    func testAddSheetNeedsACodeOnlyForANewMac() {
        let paired = [PairedHost(alias: "mac-daddy", name: "mac-daddy")]
        var f = AddHostForm()
        XCTAssertNil(f.request(paired), "nothing typed")
        XCTAssertTrue(f.needsCode(paired))
        f.address = " mac-daddy "
        XCTAssertFalse(f.needsCode(paired), "already paired: no code")
        XCTAssertEqual(f.request(paired)?.address, "mac-daddy")
        XCTAssertNil(f.request(paired)?.code)
        f.address = "mac-daddy:7800"
        XCTAssertFalse(f.needsCode(paired), "a port does not make it another Mac")
        f.address = "studio.local"
        XCTAssertTrue(f.needsCode(paired))
        XCTAssertNil(f.request(paired), "a new Mac needs its 6 digits")
        f.code = "123 456"
        XCTAssertEqual(f.request(paired)?.code, "123456")
        XCTAssertEqual(f.request(paired)?.address, "studio.local")
        f.code = "12345"
        XCTAssertNil(f.request(paired))
    }

    func testAddressParsing() {
        XCTAssertEqual(ConnectList.parseAddress("mac-daddy").host, "mac-daddy")
        XCTAssertEqual(ConnectList.parseAddress("mac-daddy").port, Mirage.defaultPort)
        XCTAssertEqual(ConnectList.parseAddress("mac-daddy:7800").port, 7800)
        XCTAssertEqual(ConnectList.parseAddress("[fd7a::1]:7801").host, "fd7a::1")
        XCTAssertEqual(ConnectList.parseAddress("[fd7a::1]:7801").port, 7801)
    }

    func testDeviceIconsResolveToTheSystemsPictures() {
        // This Mac's own model and a Mac Studio resolve to CoreTypes' exact types; an unknown model falls back to its
        // family's type, then a generic Mac's.
        XCTAssertEqual(DeviceIcon.type(model: "Mac15,14", family: nil)?.identifier.hasPrefix("com.apple.macstudio"), true)
        XCTAssertEqual(DeviceIcon.type(model: "Mac99,9", family: .macMini)?.identifier, "com.apple.macmini")
        XCTAssertEqual(DeviceIcon.type(model: nil, family: nil)?.identifier, "com.apple.mac")
        XCTAssertEqual(DeviceIcon.type(model: "iPhone17,1", family: nil)?.conforms(to: .init("com.apple.iphone")!), true)
        let icon = DeviceIcon.menuImage(model: "Mac15,14")
        XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
        XCTAssertNotEqual(DeviceIcon.image(model: "Mac15,14", family: nil).size, .zero, "the cached original keeps its size")
        XCTAssertEqual(DeviceIcon.symbolName(model: "Mac16,10", family: nil), "macmini")
        XCTAssertEqual(DeviceIcon.symbolName(model: nil, family: nil), "desktopcomputer")
    }
}
