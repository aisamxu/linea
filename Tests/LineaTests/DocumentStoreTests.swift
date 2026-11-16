import Foundation
import XCTest
@testable import Linea

final class DocumentStoreTests: XCTestCase {
    func testUTF8RoundTripIncludesChineseAndEmoji() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let url = directory.appendingPathComponent("notes.txt")
        let content = "第一行\n第二行 😀\n"

        try DocumentStore.writeText(content, to: url)
        let loaded = try DocumentStore.readText(from: url)

        XCTAssertEqual(loaded, content)
    }

    func testReadMissingFileThrowsFileMissing() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let url = directory.appendingPathComponent("missing.txt")
        XCTAssertThrowsError(try DocumentStore.readText(from: url)) { error in
            XCTAssertEqual(
                error as? DocumentStoreError,
                .fileMissing("missing.txt")
            )
        }
    }

    func testInvalidUTF8IsRejected() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let url = directory.appendingPathComponent("binary.dat")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        XCTAssertThrowsError(try DocumentStore.readText(from: url)) { error in
            XCTAssertEqual(
                error as? DocumentStoreError,
                .invalidUTF8("binary.dat")
            )
        }
    }

    func testAtomicWriteOverwritesExistingContent() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let url = directory.appendingPathComponent("overwrite.txt")
        try DocumentStore.writeText("first", to: url)
        try DocumentStore.writeText("second", to: url)

        XCTAssertEqual(try DocumentStore.readText(from: url), "second")
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(leftovers.count, 1)
    }

    func testWriteFailureIsReported() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let url = directory
            .appendingPathComponent("no-such-parent", isDirectory: true)
            .appendingPathComponent("file.txt")

        XCTAssertThrowsError(try DocumentStore.writeText("x", to: url)) { error in
            guard let storeError = error as? DocumentStoreError,
                  case .writeFailed = storeError
            else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
        }
    }

    func testSignatureChangesWhenFileChanges() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        let url = directory.appendingPathComponent("signature.txt")
        try DocumentStore.writeText("a", to: url)
        let first = try XCTUnwrap(DocumentStore.currentSignature(of: url))

        try DocumentStore.writeText("a much longer body", to: url)
        let second = try XCTUnwrap(DocumentStore.currentSignature(of: url))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.size, Int64("a much longer body".utf8.count))
    }

    func testSignatureIsNilForMissingFile() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(directory) }

        XCTAssertNil(
            DocumentStore.currentSignature(
                of: directory.appendingPathComponent("gone.txt")
            )
        )
    }

    func testNeedsDraftPolicy() {
        let url = URL(fileURLWithPath: "/tmp/saved.txt")

        let cleanSaved = Document(
            fileURL: url,
            displayName: "saved.txt",
            isDirty: false,
            savedSignature: nil
        )
        XCTAssertFalse(cleanSaved.needsDraft)

        cleanSaved.isDirty = true
        XCTAssertTrue(cleanSaved.needsDraft)

        let untitled = Document(
            fileURL: nil,
            displayName: "Untitled 1",
            isDirty: false,
            savedSignature: nil
        )
        XCTAssertTrue(untitled.needsDraft)
    }

    func testMarkSavedAndMarkReloadedUpdateDocumentIdentity() {
        let document = Document(
            fileURL: nil,
            displayName: "Untitled 1",
            isDirty: true,
            savedSignature: nil
        )
        let url = URL(fileURLWithPath: "/tmp/renamed.txt")
        let signature = FileSignature(size: 3, modificationTime: 1_700_000_000)

        document.markSaved(to: url, signature: signature)
        XCTAssertEqual(document.fileURL, url.standardizedFileURL)
        XCTAssertEqual(document.displayName, "renamed.txt")
        XCTAssertEqual(document.savedSignature, signature)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.needsDraft)

        document.isDirty = true
        document.markReloaded(from: url, signature: nil)
        XCTAssertFalse(document.isDirty)
        XCTAssertNil(document.savedSignature)
    }
}
