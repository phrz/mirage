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

  # Never replace a build Mirage's own updater installed since (a greedy upgrade or a reinstall would downgrade it):
  # the newer of the installed bundle's build and the build the host committed last (updates.json) wins.
  preflight_steps do
    run "/bin/sh", args: ["-c", <<~SH, "sh", version, "{{user}}"]
      ours=${1##*,}
      home=${HOME:-/Users/$2}
      app=${3:-/Applications/Mirage.app}
      installed=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist" 2>/dev/null || echo 0)
      committed=$(/usr/bin/plutil -extract identity.build raw -o - "$home/Library/Application Support/Mirage/updates.json" 2>/dev/null || echo 0)
      newest=$installed
      [ "$committed" -gt "$newest" ] 2>/dev/null && newest=$committed
      if [ "$newest" -gt "$ours" ] 2>/dev/null; then
        echo "Mirage build $newest is installed (it updates itself), newer than this cask's $ours: not replacing it." >&2
        echo "To go back deliberately: brew uninstall --cask mirage first." >&2
        exit 1
      fi
    SH
  end

  # Only the app: an upgrade or reinstall leaves the host agent registered (Mirage registers it again if needed). The
  # agent's job goes with zap. Pairings and the host's identity stay even then.
  uninstall quit: "com.paulherz.mirage"

  zap launchctl: "com.paulherz.mirage.host",
      trash:     [
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
