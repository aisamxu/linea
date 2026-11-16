import Foundation
@testable import Linea

enum TestSupport {
    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func removeDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func permissionBits(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = attributes[.posixPermissions] as? NSNumber
        return (number?.intValue ?? 0) & 0o777
    }

    static func makeManifest(
        sessionID: UUID = UUID(),
        windows: [WindowSnapshot]? = nil
    ) -> SessionManifest {
        let frame = WindowFrame(x: 100, y: 100, width: 900, height: 600)
        let tab = TabSnapshot(
            id: UUID(),
            filePath: "/tmp/example.txt",
            displayName: "example.txt",
            isDirty: false,
            draftFileName: nil,
            fileSignature: FileSignature(size: 12, modificationTime: 1_700_000_000),
            selections: [
                SelectionSnapshot(location: 0, length: 0),
                SelectionSnapshot(location: 4, length: 2),
            ],
            scrollOrigin: ScrollOrigin(x: 0, y: 24)
        )
        let window = WindowSnapshot(
            frame: frame,
            isActive: true,
            selectedTabIndex: 0,
            tabs: [tab]
        )
        return SessionManifest(
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            windows: windows ?? [window]
        )
    }
}
