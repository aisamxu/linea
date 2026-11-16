import Darwin
import Foundation

enum SessionStoreError: LocalizedError, Equatable {
    case corruptedManifest(String)
    case unsupportedVersion(Int)
    case readFailed(String)
    case writeFailed(String)
    case consumeFailed(String)
    case invalidDraftName(String)

    var errorDescription: String? {
        switch self {
        case let .corruptedManifest(message):
            return "The previous session could not be read: \(message)"
        case let .unsupportedVersion(version):
            return "The previous session uses unsupported format version \(version)."
        case let .readFailed(message):
            return message
        case let .writeFailed(message):
            return message
        case let .consumeFailed(message):
            return "The previous session could not be retired: \(message)"
        case let .invalidDraftName(name):
            return "Invalid session draft name: \(name)"
        }
    }
}

struct SessionRestoration {
    let manifest: SessionManifest
    let draftsDirectory: URL
}

/// 会话快照的磁盘存储。
///
/// 只允许在正常退出时调用 `write`；编辑期间不会有任何写入。
/// 启动时用 `beginRestoration` 先把清单重命名为 consumed，确保崩溃后不会重放旧会话。
final class SessionStore {
    static let orphanAge: TimeInterval = 7 * 24 * 60 * 60

    let rootURL: URL
    let sessionDirectoryURL: URL
    let sessionsDirectoryURL: URL
    let currentManifestURL: URL
    let consumedManifestURL: URL

    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        sessionDirectoryURL = rootURL.appendingPathComponent("Session", isDirectory: true)
        sessionsDirectoryURL = rootURL.appendingPathComponent("Sessions", isDirectory: true)
        currentManifestURL = sessionDirectoryURL.appendingPathComponent("current.json")
        consumedManifestURL = sessionDirectoryURL.appendingPathComponent("consumed.json")
    }

    convenience init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(rootURL: base.appendingPathComponent("Linea", isDirectory: true))
    }

    // MARK: - 写入

    func write(manifest: SessionManifest, drafts: [String: String]) throws {
        guard manifest.version == SessionManifest.currentVersion else {
            throw SessionStoreError.unsupportedVersion(manifest.version)
        }

        do {
            try ensureDirectory(rootURL)
            try ensureDirectory(sessionDirectoryURL)
            try ensureDirectory(sessionsDirectoryURL)
        } catch {
            throw SessionStoreError.writeFailed(error.localizedDescription)
        }

        let draftsDirectory = self.draftsDirectory(for: manifest.sessionID)

        do {
            try ensureDirectory(draftsDirectory)

            for (name, text) in drafts {
                try validateDraftName(name)
                guard let data = text.data(using: .utf8) else {
                    throw SessionStoreError.writeFailed("Draft \(name) is not valid UTF-8.")
                }
                try writeFileAtomically(data, to: draftsDirectory.appendingPathComponent(name))
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try writeFileAtomically(manifestData, to: currentManifestURL)
        } catch {
            let savedSessionID = currentManifestSessionID()
            if savedSessionID != manifest.sessionID {
                try? fileManager.removeItem(at: draftsDirectory)
            }
            throw error
        }

        // 清单已成功落盘，旧会话目录和 consumed 标记都可以清掉。
        try? removeIfExists(consumedManifestURL)
        removeOtherSessionDirectories(keeping: manifest.sessionID)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sessionDirectoryURL.path
        )
    }

    /// 没有任何窗口/标签时，确保下次启动不会恢复旧会话。
    func clearSession() throws {
        do {
            try removeIfExists(currentManifestURL)
            try removeIfExists(consumedManifestURL)
            try removeIfExists(sessionsDirectoryURL)
            try removeIfExists(sessionDirectoryURL)
        } catch {
            throw SessionStoreError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - 读取与消费

    func beginRestoration() throws -> SessionRestoration? {
        guard fileManager.fileExists(atPath: currentManifestURL.path) else {
            discardConsumedArtifactIfNeeded()
            cleanupOrphanSessions(olderThan: Self.orphanAge, keeping: [])
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: currentManifestURL)
        } catch {
            quarantineCurrentManifest()
            throw SessionStoreError.readFailed(
                "The previous session could not be read: \(error.localizedDescription)"
            )
        }

        let manifest: SessionManifest
        do {
            manifest = try JSONDecoder().decode(SessionManifest.self, from: data)
        } catch {
            quarantineCurrentManifest()
            throw SessionStoreError.corruptedManifest(error.localizedDescription)
        }

        guard manifest.version == SessionManifest.currentVersion else {
            quarantineCurrentManifest()
            throw SessionStoreError.unsupportedVersion(manifest.version)
        }

        // 上一次恢复若中途崩溃，会留下 consumed.json；先清掉再消费本次清单。
        discardConsumedArtifactIfNeeded()

        do {
            try fileManager.moveItem(at: currentManifestURL, to: consumedManifestURL)
        } catch {
            throw SessionStoreError.consumeFailed(error.localizedDescription)
        }

        return SessionRestoration(
            manifest: manifest,
            draftsDirectory: draftsDirectory(for: manifest.sessionID)
        )
    }

    func readDraft(named name: String, sessionID: UUID) throws -> String {
        try validateDraftName(name)
        let url = draftsDirectory(for: sessionID).appendingPathComponent(name)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SessionStoreError.readFailed(
                "A text draft needed for session restore is missing."
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionStoreError.readFailed(
                "A text draft needed for session restore is not valid UTF-8."
            )
        }
        return text
    }

    func finishRestoration(_ restoration: SessionRestoration) {
        try? removeIfExists(consumedManifestURL)
        try? fileManager.removeItem(at: draftsDirectory(for: restoration.manifest.sessionID))
        cleanupOrphanSessions(olderThan: Self.orphanAge, keeping: [])
    }

    func draftsDirectory(for sessionID: UUID) -> URL {
        sessionsDirectoryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    // MARK: - 目录与文件

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SessionStoreError.writeFailed("\(url.path) is not a directory.")
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            return
        }

        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        } catch {
            throw SessionStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// 用同目录临时文件 + rename 完成原子替换，并确保最终文件权限为 0600。
    private func writeFileAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")

        let created = fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw SessionStoreError.writeFailed(
                "Could not create a temporary file in \(directory.path)."
            )
        }

        let result: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { oldPath -> Int32 in
            url.withUnsafeFileSystemRepresentation { newPath -> Int32 in
                guard let oldPath, let newPath else { return -1 }
                return rename(oldPath, newPath)
            }
        }

        if result != 0 {
            let code = errno
            try? fileManager.removeItem(at: temporaryURL)
            throw SessionStoreError.writeFailed(
                "Could not replace \(url.lastPathComponent): \(String(cString: strerror(code)))"
            )
        }

        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func validateDraftName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              (name as NSString).lastPathComponent == name
        else {
            throw SessionStoreError.invalidDraftName(name)
        }
    }

    private func removeIfExists(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func removeOtherSessionDirectories(keeping sessionID: UUID) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls where url.lastPathComponent != sessionID.uuidString {
            try? fileManager.removeItem(at: url)
        }
    }

    private func currentManifestSessionID() -> UUID? {
        guard let data = try? Data(contentsOf: currentManifestURL),
              let manifest = try? JSONDecoder().decode(SessionManifest.self, from: data)
        else {
            return nil
        }
        return manifest.sessionID
    }

    private func quarantineCurrentManifest() {
        guard fileManager.fileExists(atPath: currentManifestURL.path) else { return }
        let failedURL = sessionDirectoryURL.appendingPathComponent(
            "failed-\(Int(Date().timeIntervalSince1970)).json"
        )
        try? removeIfExists(failedURL)
        try? fileManager.moveItem(at: currentManifestURL, to: failedURL)
    }

    private func discardConsumedArtifactIfNeeded() {
        guard fileManager.fileExists(atPath: consumedManifestURL.path) else { return }

        if let data = try? Data(contentsOf: consumedManifestURL),
           let manifest = try? JSONDecoder().decode(SessionManifest.self, from: data) {
            try? fileManager.removeItem(at: draftsDirectory(for: manifest.sessionID))
        }
        try? removeIfExists(consumedManifestURL)
    }

    func cleanupOrphanSessions(olderThan age: TimeInterval, keeping sessionIDs: Set<UUID>) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-age)
        for url in urls {
            guard let uuid = UUID(uuidString: url.lastPathComponent),
                  !sessionIDs.contains(uuid)
            else {
                continue
            }

            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            )
            guard values?.isDirectory == true else { continue }

            let modificationDate = values?.contentModificationDate ?? .distantPast
            if modificationDate < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
