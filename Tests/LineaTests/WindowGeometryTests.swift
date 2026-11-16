import AppKit
import XCTest
@testable import Linea

final class WindowGeometryTests: XCTestCase {
    private let primaryScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let secondaryScreen = NSRect(x: 1440, y: 0, width: 1920, height: 1080)

    func testVisibleFrameIsKept() {
        let frame = NSRect(x: 200, y: 150, width: 900, height: 600)
        let adjusted = WindowGeometry.adjustedFrame(
            frame,
            screenFrames: [primaryScreen],
            minimumSize: NSSize(width: 480, height: 320)
        )

        XCTAssertEqual(adjusted, frame)
    }

    func testOffscreenFrameMovesIntoNearestScreen() {
        let frame = NSRect(x: 5000, y: -500, width: 800, height: 600)
        let adjusted = WindowGeometry.adjustedFrame(
            frame,
            screenFrames: [primaryScreen, secondaryScreen],
            minimumSize: NSSize(width: 480, height: 320)
        )

        let available = secondaryScreen.insetBy(dx: 8, dy: 8)
        XCTAssertEqual(adjusted.width, 800)
        XCTAssertEqual(adjusted.height, 600)
        XCTAssertEqual(adjusted.origin.x, available.maxX - 800)
        XCTAssertEqual(adjusted.origin.y, available.minY)
    }

    func testTooSmallFrameIsExpandedToMinimumSize() {
        let frame = NSRect(x: 100, y: 100, width: 50, height: 40)
        let minimum = NSSize(width: 480, height: 320)
        let adjusted = WindowGeometry.adjustedFrame(
            frame,
            screenFrames: [primaryScreen],
            minimumSize: minimum
        )

        XCTAssertEqual(adjusted.width, minimum.width)
        XCTAssertEqual(adjusted.height, minimum.height)
        XCTAssertTrue(primaryScreen.contains(adjusted))
    }

    func testFrameLargerThanScreenIsShrunk() {
        let available = primaryScreen.insetBy(dx: 8, dy: 8)
        let frame = NSRect(x: -200, y: -200, width: 3000, height: 2000)
        let adjusted = WindowGeometry.adjustedFrame(
            frame,
            screenFrames: [primaryScreen],
            minimumSize: NSSize(width: 480, height: 320)
        )

        XCTAssertEqual(adjusted.width, available.width)
        XCTAssertEqual(adjusted.height, available.height)
        XCTAssertEqual(adjusted.origin, available.origin)
    }

    func testWindowOnSecondaryScreenStaysThere() {
        let frame = NSRect(x: 1800, y: 200, width: 900, height: 600)
        let adjusted = WindowGeometry.adjustedFrame(
            frame,
            screenFrames: [primaryScreen, secondaryScreen],
            minimumSize: NSSize(width: 480, height: 320)
        )

        XCTAssertEqual(adjusted, frame)
    }

    func testTopAndLeftEdgesAreClampedIntoScreen() {
        let frame = NSRect(x: -500, y: 850, width: 900, height: 600)
        let adjusted = WindowGeometry.adjustedFrame(
            frame,
            screenFrames: [primaryScreen],
            minimumSize: NSSize(width: 480, height: 320)
        )

        let available = primaryScreen.insetBy(dx: 8, dy: 8)
        XCTAssertEqual(adjusted.origin.x, available.minX)
        XCTAssertEqual(adjusted.origin.y, available.maxY - 600)
        XCTAssertTrue(available.contains(adjusted))
    }

    func testNonFiniteValuesAreSanitized() {
        let frame = NSRect(
            x: CGFloat.nan,
            y: CGFloat.infinity,
            width: 900,
            height: 600
        )
        let adjusted = WindowGeometry.adjustedFrame(
            frame,
            screenFrames: [primaryScreen],
            minimumSize: NSSize(width: 480, height: 320)
        )

        XCTAssertFalse(adjusted.origin.x.isNaN)
        XCTAssertFalse(adjusted.origin.y.isInfinite)
        XCTAssertTrue(primaryScreen.contains(adjusted))
    }
}
