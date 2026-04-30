import Foundation

/// Snapshots / restores the SwiftData stores that live in the app's Application Support
/// directory. Snapshots are folders named with an ISO-ish timestamp, each holding copies of
/// every `*.store`, `*.store-wal`, `*.store-shm` file present at the time of capture.
///
/// Snapshot at launch (before any writes), so the backup represents the *previous* session's
/// committed state — if the current session corrupts data, the user can roll back.
enum BackupService {

    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static var backupsRootURL: URL {
        applicationSupportURL.appendingPathComponent("Backups", isDirectory: true)
    }

    struct Snapshot: Identifiable, Hashable, Sendable {
        let id: String          // folder name (timestamp-derived)
        let url: URL
        let timestamp: Date
        let totalBytes: Int64
        let fileCount: Int
    }

    /// Captures a snapshot of the current store files. No-op when no store files exist (first
    /// install). Prunes to `maxKeep` afterwards. Failures are logged but never throw — backup
    /// is best-effort and must not block app launch.
    static func snapshotIfNeeded(maxKeep: Int = 10) {
        let storeFiles = currentStoreFiles()
        guard !storeFiles.isEmpty else { return }

        do {
            try ensureBackupsRoot()
            let dest = backupsRootURL.appendingPathComponent(timestampFolderName(), isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for src in storeFiles {
                let target = dest.appendingPathComponent(src.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: src, to: target)
            }
            prune(keep: maxKeep)
        } catch {
            print("BackupService: snapshot failed — \(error)")
        }
    }

    /// Force a fresh snapshot regardless of timing. Used for the "Back up now" button.
    @discardableResult
    static func snapshotNow(maxKeep: Int = 10) throws -> Snapshot {
        try ensureBackupsRoot()
        let folderName = timestampFolderName()
        let dest = backupsRootURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let storeFiles = currentStoreFiles()
        for src in storeFiles {
            let target = dest.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: src, to: target)
        }
        prune(keep: maxKeep)
        return try snapshot(at: dest)
    }

    static func listSnapshots() -> [Snapshot] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: backupsRootURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .compactMap { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return nil
                }
                return try? snapshot(at: url)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Restore a snapshot by overwriting the current store files. Caller should prompt the user
    /// to relaunch the app — SwiftData's `ModelContainer` is already holding an open handle to
    /// the live store and won't pick up the change until the process restarts.
    static func restore(_ snapshot: Snapshot) throws {
        let snapshotFiles = (try? FileManager.default.contentsOfDirectory(
            at: snapshot.url,
            includingPropertiesForKeys: nil
        )) ?? []

        // Wipe the current store files first so leftover sidecars (a -wal that no longer matches
        // the restored .store) don't poison the next launch.
        for live in currentStoreFiles() {
            try? FileManager.default.removeItem(at: live)
        }

        for file in snapshotFiles {
            let target = applicationSupportURL.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: file, to: target)
        }
    }

    static func delete(_ snapshot: Snapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    // MARK: - Internals

    private static func ensureBackupsRoot() throws {
        if !FileManager.default.fileExists(atPath: backupsRootURL.path) {
            try FileManager.default.createDirectory(at: backupsRootURL, withIntermediateDirectories: true)
        }
    }

    private static func currentStoreFiles() -> [URL] {
        let dir = applicationSupportURL
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.filter { url in
            let name = url.lastPathComponent
            return name.hasSuffix(".store")
                || name.hasSuffix(".store-wal")
                || name.hasSuffix(".store-shm")
        }
    }

    private static func snapshot(at url: URL) throws -> Snapshot {
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        )
        var bytes: Int64 = 0
        for entry in entries {
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += Int64(size)
        }
        let timestamp = parseTimestamp(from: url.lastPathComponent)
            ?? ((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now)
        return Snapshot(
            id: url.lastPathComponent,
            url: url,
            timestamp: timestamp,
            totalBytes: bytes,
            fileCount: entries.count
        )
    }

    private static func prune(keep: Int) {
        let snapshots = listSnapshots()
        guard snapshots.count > keep else { return }
        for snap in snapshots.dropFirst(keep) {
            try? FileManager.default.removeItem(at: snap.url)
        }
    }

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func timestampFolderName() -> String {
        // Use a sortable, filesystem-safe timestamp. Append milliseconds when colliding so two
        // back-to-back manual backups don't overwrite each other.
        let base = folderFormatter.string(from: .now)
        var candidate = base
        var i = 1
        while FileManager.default.fileExists(atPath: backupsRootURL.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(i)"
            i += 1
        }
        return candidate
    }

    private static func parseTimestamp(from folderName: String) -> Date? {
        // Strip any "-N" disambiguation suffix added on collision.
        let trimmed = folderName.split(separator: "-").prefix(2).joined(separator: "-")
        return folderFormatter.date(from: trimmed)
    }
}
