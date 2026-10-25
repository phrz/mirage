# frozen_string_literal: true

# Mirage, from the stable releases of github.com/phrz/mirage (DESIGN §3.10, U6): `brew install --cask phrz/mirage/mirage`.
# The tap is github.com/phrz/homebrew-mirage; this file is its Casks/mirage.rb. scripts/release.sh stable rewrites
# version, sha256 and url, and says to copy the file there and push. Nightlies never go to Homebrew.
cask "mirage" do
  version "0.0.0,0"
  sha256 :no_check # until the first stable release (release.sh writes the zip's SHA-256)

  url "https://github.com/phrz/mirage/releases/download/v0.0.0/Mirage-0.0.0-0.zip"
  name "Mirage"
  desc "Remote desktop for your own Macs, with a host that updates itself"
  homepage "https://github.com/phrz/mirage"

  # Mirage's own updater keeps the app current (verified, with trial, commit and rollback): brew upgrade leaves it
  # alone unless --greedy, so the two never fight over /Applications/Mirage.app.
  auto_updates true
  conflicts_with cask: "mirage@beta"
  depends_on macos: ">= :sequoia"

  app "Mirage.app"
  binary "#{appdir}/Mirage.app/Contents/MacOS/miraged"

  # The host agent goes with the app; its settings, pairings and the kept previous build stay until zap.
  uninstall launchctl: "com.paulherz.mirage.host",
            quit:      "com.paulherz.mirage"

  zap trash: [
    "~/Library/Application Support/Mirage/host-registration.json",
    "~/Library/Application Support/Mirage/pending-update.json",
    "~/Library/Application Support/Mirage/Previous",
    "~/Library/Application Support/Mirage/update-result.json",
    "~/Library/Application Support/Mirage/Updates",
    "~/Library/Application Support/Mirage/updates.json",
    "~/Library/Logs/mirage-app.log",
    "~/Library/Logs/mirage-host.log",
  ]

  caveats <<~EOS
    To let your other devices connect to this Mac, open Mirage and choose Allow Connections to This Mac in its
    menu-bar item. Then, once, in System Settings → Privacy & Security, enable miraged under:
      Screen & System Audio Recording
      Device Control and Data Access (called Accessibility before macOS 27)
    and restart the host: launchctl kickstart -k gui/$(id -u)/com.paulherz.mirage.host

    Mirage updates itself from the stable channel. To follow another one (it never downgrades):
      miraged update --set channel=beta      (or nightly, or stable)
    Pair a device from Mirage's menu bar (Pair a Device…) or with: miraged pair
  EOS
end
