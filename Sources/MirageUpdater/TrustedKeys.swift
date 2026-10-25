import Foundation

/// The manifest public keys compiled into this build (DESIGN §3.10, manifest keys and rotation).
///
/// - `compiled`: base64 raw Ed25519 public keys, `current` first, then `next`. The current key's private half lives in
///   phrz's keychain (`security … -s com.paulherz.mirage.manifest-key -a current`); the next key's only in 1Password.
///   `scripts/release.sh keys-init` generates both and writes them between the markers below.
/// - `revoked`: key IDs (`ManifestKey.keyID`) this build refuses whatever else trusts them, and drops from the keys learned
///   through `nextKey`. The compromise procedure adds the leaked key here and drops it from `compiled`.
///
/// Empty `compiled`: this build verifies no manifest, so it never updates itself (until keys-init has run).
public enum TrustedKeys {
    public static let compiled: [String] = [
        // BEGIN MIRAGE MANIFEST KEYS
        "RkdiYPOI6pgPA7XtzSH8qSYzO01fsuWk2nXTGl4sA6c=", // current c924500cb37a35e0
        "xt0I5ZG+3e8M5gXc1odsxj+dC7xjmtH2+nqCSLGn3/I=", // next fc4317d9258b2d04 (private half offline)
        // END MIRAGE MANIFEST KEYS
    ]
    public static let revoked: [String] = [
    ]
}
