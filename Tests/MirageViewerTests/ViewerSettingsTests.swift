import XCTest
import AppKit
import SwiftUI
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

    /// DESIGN §3.10 U1: when one side refused the other for its version, the row says which to update in place of the rest.
    func testRowSaysWhichSideToUpdate() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var k = known("mac-daddy", last: now)
        k.incompatibility = "hostTooOld"
        let row = ConnectList.hosts(known: ["mac-daddy": k], recent: [])[0]
        XCTAssertEqual(row.update, .hostTooOld)
        XCTAssertEqual(row.detail(now: now), "Mirage on mac-daddy is too old for this device: update mac-daddy")
        k.incompatibility = "viewerTooOld"
        XCTAssertEqual(ConnectList.hosts(known: ["mac-daddy": k], recent: [])[0].detail(now: now), "This Mirage is too old for mac-daddy: update this device")
        // A newer build on the host's feed: the arrow's data (U4 draws it); the line stays as it was.
        k.incompatibility = nil
        k.hostVersion = MirageVersion(version: "0.4.0", build: 412, commit: "a", channel: .nightly)
        k.latestAvailable = MirageVersion(version: "0.4.1", build: 420, commit: "b", channel: .nightly)
        let r2 = ConnectList.hosts(known: ["mac-daddy": k], recent: [])[0]
        XCTAssertEqual(r2.update, .updateAvailable(from: k.hostVersion!, to: k.latestAvailable!))
        XCTAssertEqual(r2.detail(now: now, locale: Locale(identifier: "en_US")), "Connected just now")
    }

    /// U4: the row's Update needs a host that takes triggers from this device; the prompt names both builds and the channel.
    @MainActor
    func testUpdatePromptAndTrigger() {
        var k = known("mac-daddy")
        k.hostVersion = MirageVersion(version: "0.1", build: 448, commit: "a", channel: .nightly)
        k.latestAvailable = MirageVersion(version: "0.1", build: 449, commit: "b", channel: .nightly)
        var row = ConnectList.hosts(known: ["mac-daddy": k], recent: [])[0]
        XCTAssertFalse(row.canTrigger, "not known to take triggers")
        XCTAssertTrue(HostUpdateCenter.promptText(row).hasPrefix("mac-daddy: 0.1 (448) → 0.1 (449), nightly"))
        XCTAssertTrue(HostUpdateCenter.promptText(row).hasSuffix("Checking mac-daddy…"), "never learned: checked, not refused (U7)")
        k.triggerFeature = false
        row = ConnectList.hosts(known: ["mac-daddy": k], recent: [])[0]
        XCTAssertTrue(HostUpdateCenter.promptText(row).contains("miraged update --now"), "a probed host without the trigger")
        k.updateTrigger = true; k.triggerFeature = true
        row = ConnectList.hosts(known: ["mac-daddy": k], recent: [])[0]
        XCTAssertTrue(row.canTrigger)
        XCTAssertEqual(HostUpdateCenter.promptText(row), "mac-daddy: 0.1 (448) → 0.1 (449), nightly")
    }

    func testLocalStatusUpdateLine() {
        var s = LocalControl.Status(hostName: "mac-daddy", pairedDevices: 1, pairingOpen: false)
        XCTAssertNil(s.updateLine, "an older host says nothing")
        s.hostVersion = MirageVersion(version: "0.1", build: 448, commit: "a", channel: .nightly)
        s.latestAvailable = MirageVersion(version: "0.1", build: 448, commit: "a", channel: .nightly)
        XCTAssertNil(s.updateLine)
        s.latestAvailable = MirageVersion(version: "0.1", build: 449, commit: "b", channel: .nightly)
        XCTAssertEqual(s.updateLine, "0.1 (448) → 0.1 (449)")
    }

    /// U7: the prompt never claims "can't be updated" from a missing record; it checks first.
    func testUpdatePromptStates() {
        var h = PairedHost(alias: "mac-daddy", name: "mac-daddy")
        h.update = .updateAvailable(from: MirageVersion(version: "0.1", build: 455, commit: "a", channel: .nightly),
                                    to: MirageVersion(version: "0.1", build: 456, commit: "b", channel: .nightly))
        XCTAssertEqual(UpdatePrompt.state(h), .checking, "never probed")
        XCTAssertTrue(UpdatePrompt.text(h).hasSuffix("Checking mac-daddy…"))
        var older = h; older.triggerFeature = false
        XCTAssertEqual(UpdatePrompt.state(older), .olderHost)
        XCTAssertTrue(UpdatePrompt.text(older).contains("miraged update --now"))
        var restricted = h; restricted.triggerFeature = true; restricted.viewerMayTrigger = false
        XCTAssertEqual(UpdatePrompt.state(restricted), .restricted)
        XCTAssertTrue(UpdatePrompt.text(restricted).contains("allows updates only on itself"))
        var can = h; can.triggerFeature = true; can.viewerMayTrigger = true; can.canTrigger = true
        XCTAssertEqual(UpdatePrompt.state(can), .canUpdate)
        XCTAssertEqual(UpdatePrompt.text(can), "mac-daddy: 0.1 (455) → 0.1 (456), nightly")
        var gone = can; gone.unreachable = true
        XCTAssertEqual(UpdatePrompt.state(gone), .unreachable)
        var legacy = h; legacy.canTrigger = true   // a U4 record (no triggerFeature yet) that said it can
        XCTAssertEqual(UpdatePrompt.state(legacy), .canUpdate)
    }

    /// U7: the row says what is known now: seen, unreachable, in use elsewhere; "Connected" only without a probe.
    func testRowSeenAndUnreachable() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let en = Locale(identifier: "en_US")
        var h = PairedHost(alias: "mac-daddy", name: "mac-daddy", lastConnected: now.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(h.detail(now: now, locale: en), "Connected 2 days ago")
        h.lastSeen = now.addingTimeInterval(-120)
        XCTAssertEqual(h.detail(now: now, locale: en), "Seen 2 minutes ago")
        h.streamingElsewhere = true
        XCTAssertEqual(h.detail(now: now, locale: en), "In use by another device")
        h.unreachable = true
        XCTAssertEqual(h.detail(now: now, locale: en), "Not reachable")
        XCTAssertTrue(h.dimmed)
        h.unreachable = false; h.refusal = "unknown device"
        XCTAssertEqual(h.detail(now: now, locale: en), "Not accepting this device", "refusing is not unreachable")
        XCTAssertTrue(h.dimmed)
        h.refusal = nil; h.unreachable = true
        XCTAssertFalse(h.detail(now: now, locale: en)!.contains("·"))
    }

    /// phrz, 2026-10-26: the row keeps one short status; build, channel, policy, model and when it was seen show only on
    /// Get Info, one plain line each.
    func testGetInfoLines() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let en = Locale(identifier: "en_US")
        var h = PairedHost(alias: "green.local", name: "green-machine", model: "Mac15,4", lastSeen: now.addingTimeInterval(-120))
        h.hostVersion = MirageVersion(version: "0.1", build: 475, commit: "abc", channel: .nightly)
        h.policy = .automatic
        XCTAssertEqual(h.detail(now: now, locale: en), "Seen 2 minutes ago", "no build or policy in the row")
        typealias R = PairedHost.InfoRow
        XCTAssertEqual(h.info(now: now, locale: en), [R(label: "Version", value: "Mirage 0.1 (475)"), R(label: "Channel", value: "Nightly"),
                                                      R(label: "Updates", value: "Automatically"), R(label: "Model", value: "Mac15,4"),
                                                      R(label: "Last seen", value: "2 minutes ago"), R(label: "Address", value: "green.local")])
        h.policy = .ask; h.unreachable = true
        XCTAssertTrue(h.info(now: now, locale: en).contains(R(label: "Updates", value: "When asked")))
        XCTAssertTrue(h.info(now: now, locale: en).contains(R(label: "Status", value: "Not reachable")))
        XCTAssertTrue(h.info(now: now, locale: en).contains(R(label: "Last seen", value: "2 minutes ago")), "when it was last seen")
        XCTAssertEqual(PairedHost(alias: "m", name: "m").info(), [], "nothing known: nothing shown")
        h.hostSettings = HostSettings(curtain: true, lockWhenFinished: false)
        let rows = h.info(now: now, locale: en)
        XCTAssertTrue(rows.contains(R(label: "Curtain", value: "On")))
        XCTAssertTrue(rows.contains(R(label: "Lock when finished", value: "Off")))
        XCTAssertTrue(rows.contains(R(label: "Stay reachable", value: "On")))
        h.hostSettings?.lockWhenFinished = true; h.lockFailedAt = now.addingTimeInterval(-7200)
        XCTAssertTrue(h.info(now: now, locale: en).contains(R(label: "Lock when finished", value: "On, but couldn't lock it 2 hours ago")))
    }

    /// DESIGN §3.12: the host's two settings travel in its Welcome (absent from older hosts).
    func testWelcomeCarriesTheHostSettings() throws {
        let w = ControlMessage.Welcome(hostName: "h", sessionID: "s", hostSettings: HostSettings(curtain: false, lockWhenFinished: true))
        let back = try JSONDecoder().decode(ControlMessage.Welcome.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(back.hostSettings, HostSettings(curtain: false, lockWhenFinished: true))
        XCTAssertNil(try JSONDecoder().decode(ControlMessage.Welcome.self, from: Data(#"{"hostName":"h","sessionID":"s"}"#.utf8)).hostSettings)
    }

    /// The list uses the Mac's own icon when it sent one (the store keeps it per host), else the generic one.
    func testListUsesTheHostsOwnIcon() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(root: tmp)
        try store.remember(host: .init(hostID: "abc1", hostName: "green", publicKey: Data(), endpoint: "green", pairedAt: Date()), as: "green")
        try store.remember(host: .init(hostID: "abc2", hostName: "old", publicKey: Data(), endpoint: "old", pairedAt: Date()), as: "old")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try store.saveHostIcon(HostIcon.make(png128: png, png256: nil)!, hostID: "abc1")
        let rows = ConnectList.load(store: store, defaults: defaults)
        XCTAssertEqual(rows.first { $0.alias == "green" }?.icon, png)
        XCTAssertNil(rows.first { $0.alias == "old" }?.icon, "an older host: the generic icon")
    }

    /// U7: no probe while a session to that host is open (its own Welcome keeps the record); otherwise one is made.
    @MainActor
    func testNoProbeWhileASessionIsOpen() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-probes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(root: tmp)
        try store.remember(host: .init(hostID: "h", hostName: "mac-daddy", publicKey: Data(), endpoint: "mac-daddy", pairedAt: Date()), as: "mac-daddy")
        let center = HostProbeCenter.shared
        let saved = (center.sessionOpen, center.store, center.connector)
        defer { (center.sessionOpen, center.store, center.connector) = saved }
        center.store = { store }
        center.connector = { _ in { throw MirageError.transport("unreachable in the test") } }
        center.sessionOpen = { $0 == "mac-daddy" }
        let before = center.probesRun
        await center.probeNow("mac-daddy")
        XCTAssertEqual(center.probesRun, before, "a session is open: no probe")
        XCTAssertNil(try store.knownHosts()["mac-daddy"]?.unreachableSince)
        center.sessionOpen = { _ in false }
        await center.probeNow("mac-daddy")
        XCTAssertEqual(center.probesRun, before + 1)
        XCTAssertNotNil(try store.knownHosts()["mac-daddy"]?.unreachableSince)
    }

    /// U6 review 6: a status never overwrites a step under way from this app's own update; a rollback reported after the
    /// restart shows once.
    @MainActor
    func testTheHostBarsStep() {
        let m = LocalHostUpdate()
        let mine = ControlMessage.UpdateStatus(phase: .downloading, message: "downloading", yours: true)
        m.apply(event: mine, updating: nil, lastUpdate: nil)
        m.apply(event: nil, updating: nil, lastUpdate: nil)
        XCTAssertEqual(m.step, mine, "a status without an update does not clear this app's step")
        let elsewhere = ControlMessage.UpdateStatus(phase: .verifying, message: "verifying (Automatic)", yours: true)
        m.apply(event: nil, updating: elsewhere, lastUpdate: nil)
        XCTAssertEqual(m.step, mine, "nor does one running elsewhere replace it")
        let fresh = LocalHostUpdate()
        fresh.apply(event: nil, updating: elsewhere, lastUpdate: nil)
        XCTAssertEqual(fresh.step, elsewhere)
        fresh.apply(event: nil, updating: nil, lastUpdate: nil)
        XCTAssertNil(fresh.step, "it goes when the host's update ends")
        let rolled = ControlMessage.UpdateStatus(phase: .rolledBack, message: "started 3 times", at: Date(timeIntervalSince1970: 100))
        fresh.apply(event: nil, updating: nil, lastUpdate: rolled)
        XCTAssertEqual(fresh.step, rolled, "the rollback shows")
        fresh.dismissStep()
        fresh.apply(event: nil, updating: nil, lastUpdate: rolled)
        XCTAssertNil(fresh.step, "once")
    }

    /// Remove (phrz, 2026-10-26): an open session ends first; this device forgets the Mac (record, recents, last host)
    /// whatever the Mac said, and the note says which.
    @MainActor
    func testRemovingAHost() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(root: tmp)
        try store.remember(host: .init(hostID: "h", hostName: "mac-daddy", publicKey: Data(), endpoint: "mac-daddy", pairedAt: Date()), as: "mac-daddy")
        ViewerSettings.noteConnected("mac-daddy", defaults)
        let center = HostRemovalCenter.shared
        let saved = (center.endSession, center.store, center.connector, center.defaults)
        defer { (center.endSession, center.store, center.connector, center.defaults) = saved }
        final class Ended: @unchecked Sendable { var aliases: [String] = [] }
        let ended = Ended()
        center.endSession = { ended.aliases.append($0) }
        center.store = { store }
        center.defaults = defaults
        center.connector = { _ in { throw MirageError.transport("unreachable in the test") } }
        await center.remove(PairedHost(alias: "mac-daddy", name: "mac-daddy"))
        XCTAssertEqual(ended.aliases, ["mac-daddy"], "the session to it ended first")
        XCTAssertNil(try store.knownHosts()["mac-daddy"])
        XCTAssertEqual(ViewerSettings.recentHosts(defaults), [])
        XCTAssertNil(defaults.string(forKey: "lastHost"))
        // phrz, 2026-10-26: no footer that stays; an alert to acknowledge, with the Mac's state.
        XCTAssertNil(ListNotices.shared.note, "nothing under the list")
        XCTAssertEqual(ListNotices.shared.current, ListAlert(title: "Removed mac-daddy from this device.",
                                                             message: "It couldn't be reached, so it still lists this device until you revoke it in its menu bar."))
        ListNotices.shared.dismiss()
        XCTAssertNil(ListNotices.shared.current, "OK dismisses it: nothing kept")
        XCTAssertNil(HostRemovalCenter.alert(.unpaired, name: "mac-daddy"), "a clean removal: the row going is enough")
        XCTAssertNotNil(HostRemovalCenter.alert(.notSupported, name: "mac-daddy"))
        XCTAssertEqual(HostRemovalCenter.confirmation("mac-daddy").title, "Remove mac-daddy?")
        XCTAssertEqual(HostRemovalCenter.confirmation("mac-daddy").message, "This device will need to pair again to connect.")
    }

    /// A passing note clears itself; alerts wait for OK, one at a time.
    func testNotesPassAndAlertsWait() async throws {
        let n = ListNotices.shared
        n.reset()
        let saved = n.lifetime
        defer { n.lifetime = saved; n.reset() }
        n.lifetime = .milliseconds(50)
        n.flash("studio is ready.")
        XCTAssertEqual(n.note, "studio is ready.")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(n.note, "gone by itself")
        n.alert(ListAlert(title: "a", message: "1")); n.alert(ListAlert(title: "a", message: "1")); n.alert(ListAlert(title: "b", message: "2"))
        XCTAssertEqual(n.alerts.count, 2, "the same alert once")
        XCTAssertEqual(n.current?.title, "a")
        n.dismiss()
        XCTAssertEqual(n.current?.title, "b")
        n.dismiss()
        XCTAssertNil(n.current)
    }

    /// An update from here: the row line shows only while it runs; done is a passing note, a failure an alert.
    func testUpdateOutcomesDoNotStayInTheList() {
        let n = ListNotices.shared, c = HostUpdateCenter.shared
        n.reset()
        defer { n.reset() }
        c.finish("mac-daddy", name: "mac-daddy", .init(phase: .done, message: "now 0.1 (480)"))
        XCTAssertNil(c.line("mac-daddy"), "the row has its own status again")
        XCTAssertEqual(n.note, "Updated mac-daddy: now 0.1 (480)")
        c.finish("mac-daddy", name: "mac-daddy", .init(phase: .rolledBack, message: "started 3 times"))
        XCTAssertEqual(n.current?.title, "mac-daddy rolled back its update")
    }

    /// How an update's end reaches the person: the host's reason as an alert, a passing note when it simply worked, nothing
    /// when the host never answered (its row says Not reachable).
    func testUpdateOutcomeNotices() {
        typealias S = ControlMessage.UpdateStatus
        XCTAssertEqual(UpdateOutcomeNotice.make(S(phase: .unknown, message: "green-machine has not answered", unanswered: true), name: "g"), .quiet)
        XCTAssertEqual(UpdateOutcomeNotice.make(S(phase: .failed, message: "x", notPublished: true), name: "g"),
                       .note("g doesn't see that build yet. Try again in a few minutes."))
        XCTAssertEqual(UpdateOutcomeNotice.make(S(phase: .done, message: "g runs 0.1 (483)"), name: "g"), .note("Updated g: g runs 0.1 (483)"))
        guard case .alert(let grant) = UpdateOutcomeNotice.make(S(phase: .done, message: "g runs 0.1 (483); Screen Recording missing (System Settings)"), name: "g") else { return XCTFail() }
        XCTAssertTrue(grant.title.contains("needs a permission"))
        guard case .alert(let rb) = UpdateOutcomeNotice.make(S(phase: .rolledBack, message: "not healthy within 5 min"), name: "g") else { return XCTFail() }
        XCTAssertEqual(rb.message, "not healthy within 5 min")
        guard case .alert(let trial) = UpdateOutcomeNotice.make(S(phase: .unknown, message: "g runs 0.1 (483), checking its health (waiting for a screen capture)"), name: "g") else { return XCTFail() }
        XCTAssertTrue(trial.message.contains("waiting for a screen capture"))
    }

    /// The viewer reads a channel again only after 30-60 min (review, 2026-10-27: the API's 60 an hour are shared).
    func testViewerFeedChecksAreThrottledPerChannel() {
        let now = Date()
        XCTAssertTrue(ViewerFeedCenter.due(nil, now: now), "never read")
        XCTAssertFalse(ViewerFeedCenter.due(now.addingTimeInterval(-25 * 60), now: now), "read 25 min ago")
        XCTAssertTrue(ViewerFeedCenter.due(now.addingTimeInterval(-61 * 60), now: now))
        XCTAssertTrue(ViewerFeedCenter.due(now.addingTimeInterval(600), now: now), "a clock that moved back")
        for _ in 0..<50 { let f = ViewerFeedCenter.freshFor(); XCTAssertTrue((1800...3600).contains(f)) }
    }

    /// The permissions window (DESIGN §3.7a): the first Allow asks the host (macOS shows its sheet), a later one opens the
    /// exact pane; rows follow the host's status; it comes up only for a missing grant and not again once put away.
    func testPermissionsWindowModel() {
        let m = PermissionsModel()
        final class Log { var sent: [String] = []; var opened: [URL] = [] }
        let log = Log()
        m.request = { log.sent.append($0) }
        m.openSettings = { log.opened.append($0) }
        var s = LocalControl.Status(hostName: "big-mac", pairedDevices: 0, pairingOpen: false, screenRecording: true, accessibility: false)
        m.apply(s)
        XCTAssertEqual(m.grants.map(\.granted), [true, false])
        XCTAssertEqual(m.grants.map(\.title), [PrivacyPane.screenRecording, PrivacyPane.accessibility()])
        XCTAssertEqual(m.headline, "Mirage needs one more permission to share this Mac.")
        m.allow("accessibility")
        XCTAssertEqual(log.sent, ["accessibility"]); XCTAssertTrue(log.opened.isEmpty, "the first time: the system's own sheet")
        m.allow("accessibility")
        XCTAssertEqual(log.opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
        XCTAssertEqual(log.sent, ["accessibility"], "the second Allow only opens Settings")
        // The host remembers what it asked (another launch of the app): straight to the pane.
        let m2 = PermissionsModel()
        s.permissionsAsked = ["screenRecording"]
        m2.apply(s)
        XCTAssertEqual(PermissionsModel.allowAction(for: "screenRecording", asked: m2.asked), .openSettings)
        XCTAssertEqual(PermissionsModel.allowAction(for: "accessibility", asked: m2.asked), .request)
        XCTAssertTrue(PermissionsWindow.shouldShow(s, visible: false, dismissed: false))
        XCTAssertFalse(PermissionsWindow.shouldShow(s, visible: false, dismissed: true), "put away this launch")
        XCTAssertFalse(PermissionsWindow.shouldShow(s, visible: true, dismissed: false))
        s.accessibility = true
        XCTAssertFalse(PermissionsWindow.shouldShow(s, visible: false, dismissed: false), "all granted")
        m.apply(s)
        XCTAssertTrue(m.allGranted)
        XCTAssertEqual(m.headline, "This Mac is ready. Your paired devices can connect.")
        let old = LocalControl.Status(hostName: "old", pairedDevices: 0, pairingOpen: false)
        XCTAssertFalse(PermissionsWindow.shouldShow(old, visible: false, dismissed: false), "an older host that does not say: nothing shown")
        for line in m.grants.flatMap({ [$0.title, $0.why] }) + [m.headline] { XCTAssertFalse(line.contains("·"), line) }
    }

    /// Get Info on the Mac: one small window per Mac, "<host> Info", not resizable, brought forward when asked again.
    func testGetInfoWindow() {
        var h = PairedHost(alias: "green.local", name: "green-machine", model: "Mac15,4")
        h.hostVersion = MirageVersion(version: "0.1", build: 475, commit: "abc", channel: .nightly)
        let p = HostInfoWindows.show(h, present: false)
        defer { p.close() }
        XCTAssertEqual(p.title, "green-machine Info")
        XCTAssertFalse(p.styleMask.contains(.resizable))
        XCTAssertTrue(p.styleMask.contains(.closable))
        XCTAssertTrue(HostInfoWindows.show(h, present: false) === p, "one per Mac")
        XCTAssertEqual((p.contentViewController as? NSHostingController<HostInfoView>)?.rootView.host.info().first,
                       PairedHost.InfoRow(label: "Version", value: "Mirage 0.1 (475)"))
        let other = HostInfoWindows.show(PairedHost(alias: "mini", name: "mini"), present: false)
        defer { other.close() }
        XCTAssertFalse(other === p)
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
