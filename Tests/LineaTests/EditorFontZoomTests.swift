import AppKit
import XCTest
@testable import Linea

/// 字号缩放：范围夹取、偏好持久化与布局重建。
@MainActor
final class EditorFontZoomTests: XCTestCase {
    func testClampedFontSizeUsesSupportedRangeAndWholePoints() {
        XCTAssertEqual(EditorPreferences.clamped(8), 10)
        XCTAssertEqual(EditorPreferences.clamped(30), 24)
        XCTAssertEqual(EditorPreferences.clamped(13.4), 13)
        XCTAssertEqual(EditorPreferences.clamped(13.6), 14)
    }

    func testFontSizePersistsInInjectedDefaults() {
        let suiteName = "LineaFontZoomTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(EditorPreferences.fontSize(in: defaults), 13)

        EditorPreferences.setFontSize(18, in: defaults)
        XCTAssertEqual(EditorPreferences.fontSize(in: defaults), 18)

        // 超出范围的值写入时夹取，读回时也保持合法。
        EditorPreferences.setFontSize(100, in: defaults)
        XCTAssertEqual(EditorPreferences.fontSize(in: defaults), 24)
    }

    func testApplyFontSizeRebuildsLayoutAndUpdatesTheme() {
        let document = Document(
            fileURL: nil,
            displayName: "Font Zoom",
            isDirty: false,
            savedSignature: nil
        )
        let editor = EditorViewController(
            document: document,
            text: "one\ntwo\nthree",
            selections: [NSRange(location: 0, length: 0)]
        )
        let oldLineHeight = editor.textView.layoutEngine.lineHeight

        editor.applyFontSize(20)

        XCTAssertEqual(editor.textView.theme.fontSize, 20)
        XCTAssertGreaterThan(editor.textView.layoutEngine.lineHeight, oldLineHeight)
        XCTAssertEqual(
            editor.textView.documentHeight,
            editor.textView.layoutEngine.lineHeight * 3
        )
    }
}
