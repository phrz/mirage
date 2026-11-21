import MirageCore

/// This build of the Linux host. linux/release.sh stamps `number` (the commit count of the branch it is built from) and
/// `commit` for a release; a development build is 0 and never replaces an installed release.
enum LinuxBuild {
    static let number = 0
    static let commit = "dev"
}

/// The manifest keys the Linux host trusts: its own key, apart from the Mac's (TrustedKeys.linux; the private half is
/// ~/.config/mirage/linux-manifest-key.json on phrz-mini-m4-pro, which linux/release.sh signs with).
enum LinuxTrustedKeys {
    static let compiled: [String] = TrustedKeys.linux
}
