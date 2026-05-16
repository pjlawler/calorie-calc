import Foundation

/// Stable per-Apple-ID identifier that survives uninstall/reinstall, used to gate the
/// one-time initial-credit grant on the proxy. The App Attest `keyId` is per-install,
/// so on its own it lets a user reinstall to re-roll the free-credit grant; pairing it
/// with an iCloud-synced UUID raises the bar — uninstalling and reinstalling on the
/// same Apple ID lands on the same id, and the proxy treats the grant as already given.
///
/// Sources, in priority order:
///   1. `NSUbiquitousKeyValueStore` — iCloud-synced across the user's devices and
///      installs. If iCloud has a value at launch, that's the truth.
///   2. `UserDefaults` — local fallback so the id stays usable when iCloud is
///      unavailable (signed out, no network, sim).
///   3. Newly-minted UUID — true first install on this Apple ID. Written to both
///      stores so the next launch and any future reinstalls find it.
///
/// Bypassable by a user who signs out of iCloud or uses a different Apple ID — that's
/// accepted friction, not iron-clad. If credit-replay abuse shows up in the wild, the
/// next step is keying off `CKContainer.fetchUserRecordID()` (Apple-anchored identity,
/// requires iCloud sign-in).
final class InstallIdentity: @unchecked Sendable {
    static let shared = InstallIdentity()

    nonisolated private static let key = "installId"

    // Observer is set once in init and only read by deinit; NSObjectProtocol is not Sendable,
    // so nonisolated(unsafe) documents that the access pattern is safe in practice (no shared
    // mutation after init) without forcing the singleton to hop actors on tear-down.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// Current install id, suitable for the `X-Install-Id` header. Reads from
    /// `UserDefaults` on every call so a late-arriving iCloud value (delivered via
    /// `didChangeExternallyNotification` after launch) takes effect on the next request.
    var id: String {
        UserDefaults.standard.string(forKey: Self.key) ?? ""
    }

    private init() {
        let defaults = UserDefaults.standard
        let icloud = NSUbiquitousKeyValueStore.default
        icloud.synchronize()

        let localId = defaults.string(forKey: Self.key)
        let cloudId = icloud.string(forKey: Self.key)

        if let cloud = cloudId, !cloud.isEmpty {
            // iCloud already has an id from a prior install — use it and refresh the
            // local cache so reads of `id` return the iCloud-anchored value.
            if cloud != localId {
                defaults.set(cloud, forKey: Self.key)
            }
        } else if let local = localId, !local.isEmpty {
            // We have a local id but iCloud doesn't yet — push it up so a future
            // reinstall on the same Apple ID can recover it.
            icloud.set(local, forKey: Self.key)
            icloud.synchronize()
        } else {
            // True first install on this Apple ID (or iCloud unavailable). Mint a new
            // id and write it to both stores.
            let new = UUID().uuidString
            defaults.set(new, forKey: Self.key)
            icloud.set(new, forKey: Self.key)
            icloud.synchronize()
        }

        // iCloud KV sync can arrive after launch — on a fresh reinstall the iCloud
        // value may land seconds *after* the app started and we already minted a new
        // local id. When that happens, prefer the iCloud value for all *future*
        // requests; the proxy will still see the freshly-minted id in any header
        // already sent, but most users won't make their first AI call inside that race.
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: icloud,
            queue: nil
        ) { _ in
            guard
                let cloud = NSUbiquitousKeyValueStore.default.string(forKey: Self.key),
                !cloud.isEmpty
            else { return }
            UserDefaults.standard.set(cloud, forKey: Self.key)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
