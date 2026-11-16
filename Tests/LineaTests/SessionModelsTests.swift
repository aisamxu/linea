import AppKit
import XCTest
@testable import Linea

final class SessionModelsTests: XCTestCase {
    func testManifestRoundTrip() throws {
        let manifest = TestSupport.makeManifest()

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.version, SessionManifest.currentVersion)
    }

    func testWindowFrameConvertsToAndFromRect() {
        let rect = NSRect(x: 12.5, y: -40, width: 900, height: 600)
        let frame = WindowFrame(rect)

        XCTAssertEqual(frame.x, rect.origin.x)
        XCTAssertEqual(frame.y, rect.origin.y)
        XCTAssertEqual(frame.width, rect.width)
        XCTAssertEqual(frame.height, rect.height)
        XCTAssertEqual(frame.rect, rect)
    }

    func testSelectionSnapshotConvertsToAndFromRange() {
        let range = NSRange(location: 17, length: 4)
        let snapshot = SelectionSnapshot(range)

        XCTAssertEqual(snapshot.location, 17)
        XCTAssertEqual(snapshot.length, 4)
        XCTAssertEqual(snapshot.nsRange, range)
    }

    func testScrollOriginConvertsToAndFromPoint() {
        let point = CGPoint(x: 120, y: 480)
        let origin = ScrollOrigin(point)

        XCTAssertEqual(origin.x, 120)
        XCTAssertEqual(origin.y, 480)
        XCTAssertEqual(origin.point, point)
    }

    func testTabSnapshotPreservesDraftMetadata() throws {
        let tabID = UUID()
        let tab = TabSnapshot(
            id: tabID,
            filePath: "/tmp/notes.txt",
            displayName: "notes.txt",
            isDirty: true,
            draftFileName: "\(tabID.uuidString).txt",
            fileSignature: FileSignature(size: 42, modificationTime: 1_700_000_000),
            selections: [
                SelectionSnapshot(location: 0, length: 3),
                SelectionSnapshot(location: 10, length: 0),
            ],
            scrollOrigin: ScrollOrigin(x: 0, y: 120)
        )

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        XCTAssertEqual(decoded, tab)
        XCTAssertEqual(decoded.draftFileName, "\(tabID.uuidString).txt")
        XCTAssertEqual(decoded.selections.last?.location, 10)
    }

    func testFileSignatureCodableRoundTrip() throws {
        let signature = FileSignature(size: 1_024, modificationTime: 1_700_000_000.125)

        let data = try JSONEncoder().encode(signature)
        let decoded = try JSONDecoder().decode(FileSignature.self, from: data)

        XCTAssertEqual(decoded, signature)
    }
}
