import AppKit
import Foundation
import Testing
@testable import LineaTextUI

/// 拖入文件的纯文本筛选。
@Suite("TextFileDrop")
@MainActor
struct TextFileDropTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("linea-test-\(UUID().uuidString)"))
    }

    @Test func acceptsCommonTextExtensions() {
        let extensions = [
            "txt", "text", "log", "md", "markdown",
            "json", "csv", "sh", "swift", "yaml",
        ]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(TextFileDrop.isTextFile(url), "应接受 .\(ext)")
        }
    }

    @Test func rejectsKnownBinaryExtensions() {
        let extensions = ["png", "jpg", "zip", "pdf", "dmg", "mp4"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(!TextFileDrop.isTextFile(url), "应拒绝 .\(ext)")
        }
    }

    @Test func acceptsMissingOrUnknownExtension() {
        // 无扩展名和系统未登记的扩展名都无法从 UTI 判断，交给 UTF-8 读取层。
        #expect(TextFileDrop.isTextFile(URL(fileURLWithPath: "/tmp/Makefile")))
        #expect(TextFileDrop.isTextFile(URL(fileURLWithPath: "/tmp/sample.unknown-ext")))
    }

    @Test func rejectsDirectoriesAndNonFileURLs() {
        let directory = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        #expect(!TextFileDrop.isTextFile(directory))

        let remote = URL(string: "https://example.com/test.txt")!
        #expect(!TextFileDrop.isTextFile(remote))
    }

    @Test func readsTextFileURLsFromPasteboard() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/linea-drop.txt") as NSURL,
            URL(fileURLWithPath: "/tmp/linea-drop.png") as NSURL,
        ])

        let urls = TextFileDrop.fileURLs(from: pasteboard)
        #expect(urls.map(\.lastPathComponent) == ["linea-drop.txt"])
    }

    @Test func ignoresPasteboardWithoutFileURL() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)

        #expect(TextFileDrop.fileURLs(from: pasteboard).isEmpty)
    }
}
