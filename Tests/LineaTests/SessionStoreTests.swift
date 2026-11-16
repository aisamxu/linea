import Foundation
import XCTest
@testable import Linea

final class SessionStoreTests: XCTestCase {
    func testWriteAndBeginRestorationRoundTrip() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let manifest = TestSupport.makeManifest()

        try store.write(manifest: manifest, drafts: [:])

        XCTAssertEqual(
            try TestSupport.permissionBits(at: store.sessionDirectoryURL),
            0o700
        )
        XCTAssertEqual(
            try TestSupport.permissionBits(at: store.sessionsDirectoryURL),
            0o700
        )
        XCTAssertEqual(
            try TestSupport.permissionBits(at: store.currentManifestURL),
            0o600
        )

        let restoration = try XCTUnwrap(try store.beginRestoration())
        XCTAssertEqual(restoration.manifest, manifest)
        XCTAssertFalse(store.fileExists(at: store.currentManifestURL))
        XCTAssertTrue(store.fileExists(at: store.consumedManifestURL))

        store.finishRestoration(restoration)
        XCTAssertFalse(store.fileExists(at: store.consumedManifestURL))
        XCTAssertFalse(store.fileExists(at: restoration.draftsDirectory))
        XCTAssertNil(try store.beginRestoration())
    }

    func testDraftsForDirtyAndUntitledTabsRoundTrip() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let manifest = makeManifestWithDrafts()

        try store.write(manifest: manifest, drafts: sampleDrafts())
        let restoration = try XCTUnwrap(try store.beginRestoration())

        let drafts = restoration.draftsDirectory
        XCTAssertEqual(
            try TestSupport.permissionBits(at: drafts),
            0o700
        )
        XCTAssertEqual(
            try TestSupport.permissionBits(at: drafts.appendingPathComponent("dirty.txt")),
            0o600
        )
        XCTAssertEqual(
            try store.readDraft(named: "dirty.txt", sessionID: manifest.sessionID),
            "未保存的磁盘草稿\n"
        )
        XCTAssertEqual(
            try store.readDraft(named: "untitled.txt", sessionID: manifest.sessionID),
            ""
        )

        store.finishRestoration(restoration)
    }

    func testManifestNeverEmbedsDraftText() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let manifest = makeManifestWithDrafts()
        let secret = "只在草稿里出现的正文"
        var drafts = sampleDrafts()
        drafts["dirty.txt"] = secret

        try store.write(manifest: manifest, drafts: drafts)

        let manifestText = try String(
            contentsOf: store.currentManifestURL,
            encoding: .utf8
        )
        XCTAssertFalse(manifestText.contains(secret))
        XCTAssertFalse(manifestText.contains("未保存的磁盘草稿"))
    }

    func testCleanFileDoesNotRequireDraft() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let manifest = TestSupport.makeManifest()

        try store.write(manifest: manifest, drafts: [:])
        let restoration = try XCTUnwrap(try store.beginRestoration())

        let tab = try XCTUnwrap(restoration.manifest.windows.first?.tabs.first)
        XCTAssertNil(tab.draftFileName)
        XCTAssertFalse(tab.isDirty)

        store.finishRestoration(restoration)
    }

    func testSecondRestorationDoesNotReplayConsumedSession() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let manifest = makeManifestWithDrafts()
        try store.write(manifest: manifest, drafts: sampleDrafts())

        let first = try XCTUnwrap(try store.beginRestoration())
        XCTAssertEqual(first.manifest.sessionID, manifest.sessionID)

        XCTAssertNil(try store.beginRestoration())
        XCTAssertFalse(store.fileExists(at: store.consumedManifestURL))
        XCTAssertFalse(store.fileExists(at: first.draftsDirectory))
    }

    func testCorruptedManifestIsArchivedAndNotReplayed() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        try FileManager.default.createDirectory(
            at: store.sessionDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("{ this is not json".utf8).write(to: store.currentManifestURL)

        XCTAssertThrowsError(try store.beginRestoration()) { error in
            guard let storeError = error as? SessionStoreError,
                  case .corruptedManifest = storeError
            else {
                return XCTFail("Expected corruptedManifest, got \(error)")
            }
        }

        XCTAssertFalse(store.fileExists(at: store.currentManifestURL))
        let files = try FileManager.default.contentsOfDirectory(
            at: store.sessionDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasPrefix("failed-") })
        XCTAssertNil(try store.beginRestoration())
    }

    func testUnsupportedManifestVersionIsArchived() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        try FileManager.default.createDirectory(
            at: store.sessionDirectoryURL,
            withIntermediateDirectories: true
        )

        var manifest = TestSupport.makeManifest()
        manifest.version = 99
        try JSONEncoder().encode(manifest).write(to: store.currentManifestURL)

        XCTAssertThrowsError(try store.beginRestoration()) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                .unsupportedVersion(99)
            )
        }

        XCTAssertFalse(store.fileExists(at: store.currentManifestURL))
        XCTAssertNil(try store.beginRestoration())
    }

    func testWriteRejectsUnsupportedVersionBeforeCreatingManifest() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        var manifest = TestSupport.makeManifest()
        manifest.version = 42

        XCTAssertThrowsError(try store.write(manifest: manifest, drafts: [:])) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                .unsupportedVersion(42)
            )
        }
        XCTAssertFalse(store.fileExists(at: store.currentManifestURL))
    }

    func testWritingNewSessionRemovesPreviousSessionDirectories() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let firstManifest = TestSupport.makeManifest()
        try store.write(manifest: firstManifest, drafts: [:])
        XCTAssertTrue(store.fileExists(at: store.draftsDirectory(for: firstManifest.sessionID)))

        let secondManifest = TestSupport.makeManifest()
        try store.write(manifest: secondManifest, drafts: [:])

        XCTAssertFalse(store.fileExists(at: store.draftsDirectory(for: firstManifest.sessionID)))
        XCTAssertTrue(store.fileExists(at: store.draftsDirectory(for: secondManifest.sessionID)))
    }

    func testOrphanSessionsAreRemovedButKeptSessionSurvives() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        try FileManager.default.createDirectory(
            at: store.sessionsDirectoryURL,
            withIntermediateDirectories: true
        )

        let oldID = UUID()
        let recentID = UUID()
        let keptID = UUID()
        let oldURL = store.draftsDirectory(for: oldID)
        let recentURL = store.draftsDirectory(for: recentID)
        let keptURL = store.draftsDirectory(for: keptID)
        for url in [oldURL, recentURL, keptURL] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(SessionStore.orphanAge + 3_600))],
            ofItemAtPath: oldURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(SessionStore.orphanAge + 3_600))],
            ofItemAtPath: keptURL.path
        )

        store.cleanupOrphanSessions(
            olderThan: SessionStore.orphanAge,
            keeping: [keptID]
        )

        XCTAssertFalse(store.fileExists(at: oldURL))
        XCTAssertTrue(store.fileExists(at: recentURL))
        XCTAssertTrue(store.fileExists(at: keptURL))
    }

    func testClearSessionRemovesManifestAndDrafts() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let manifest = makeManifestWithDrafts()
        try store.write(manifest: manifest, drafts: sampleDrafts())
        XCTAssertTrue(store.fileExists(at: store.currentManifestURL))

        try store.clearSession()

        XCTAssertFalse(store.fileExists(at: store.currentManifestURL))
        XCTAssertFalse(store.fileExists(at: store.consumedManifestURL))
        XCTAssertFalse(store.fileExists(at: store.sessionsDirectoryURL))
        XCTAssertFalse(store.fileExists(at: store.sessionDirectoryURL))
    }

    func testDraftPathTraversalIsRejected() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let manifest = TestSupport.makeManifest()

        XCTAssertThrowsError(
            try store.write(manifest: manifest, drafts: ["../escape.txt": "bad"])
        ) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                .invalidDraftName("../escape.txt")
            )
        }
        XCTAssertFalse(store.fileExists(at: store.currentManifestURL))
        XCTAssertFalse(store.fileExists(at: store.draftsDirectory(for: manifest.sessionID)))

        try store.write(manifest: manifest, drafts: [:])
        XCTAssertThrowsError(
            try store.readDraft(named: "../escape.txt", sessionID: manifest.sessionID)
        ) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                .invalidDraftName("../escape.txt")
            )
        }
    }

    func testMissingDraftIsReportedAsReadFailure() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let store = SessionStore(rootURL: directory)
        let manifest = makeManifestWithDrafts()
        try store.write(manifest: manifest, drafts: sampleDrafts())

        XCTAssertThrowsError(
            try store.readDraft(named: "missing.txt", sessionID: manifest.sessionID)
        ) { error in
            guard let storeError = error as? SessionStoreError,
                  case .readFailed = storeError
            else {
                return XCTFail("Expected readFailed, got \(error)")
            }
        }
    }

    // MARK: - 辅助

    private func makeManifestWithDrafts() -> SessionManifest {
        let dirtyTab = TabSnapshot(
            id: UUID(),
            filePath: "/tmp/dirty.txt",
            displayName: "dirty.txt",
            isDirty: true,
            draftFileName: "dirty.txt",
            fileSignature: FileSignature(size: 10, modificationTime: 1_700_000_000),
            selections: [SelectionSnapshot(location: 2, length: 0)],
            scrollOrigin: ScrollOrigin(x: 0, y: 30)
        )
        let untitledTab = TabSnapshot(
            id: UUID(),
            filePath: nil,
            displayName: "Untitled 1",
            isDirty: false,
            draftFileName: "untitled.txt",
            fileSignature: nil,
            selections: [SelectionSnapshot(location: 0, length: 0)],
            scrollOrigin: ScrollOrigin(x: 0, y: 0)
        )
        let window = WindowSnapshot(
            frame: WindowFrame(x: 0, y: 0, width: 900, height: 600),
            isActive: true,
            selectedTabIndex: 1,
            tabs: [dirtyTab, untitledTab]
        )
        return SessionManifest(
            sessionID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            windows: [window]
        )
    }

    private func sampleDrafts() -> [String: String] {
        [
            "dirty.txt": "未保存的磁盘草稿\n",
            "untitled.txt": "",
        ]
    }
}
