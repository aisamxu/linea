import AppKit

/// 窗口坐标校正的纯逻辑，便于单元测试。
enum WindowGeometry {
    static let minimumSize = NSSize(width: 480, height: 320)

    /// 把恢复的 window frame 调整到可见屏幕内。
    /// - Parameters:
    ///   - frame: 快照中保存的 frame（NSWindow 坐标，原点在左下）。
    ///   - screenFrames: 各屏幕的 visibleFrame。
    ///   - minimumSize: 最小可用尺寸。
    static func adjustedFrame(
        _ frame: NSRect,
        screenFrames: [NSRect],
        minimumSize: NSSize = minimumSize
    ) -> NSRect {
        guard !screenFrames.isEmpty else { return frame }

        let finiteFrame = NSRect(
            x: frame.origin.x.isFinite ? frame.origin.x : 0,
            y: frame.origin.y.isFinite ? frame.origin.y : 0,
            width: frame.width.isFinite ? frame.width : minimumSize.width,
            height: frame.height.isFinite ? frame.height : minimumSize.height
        )

        let targetScreen = bestScreen(for: finiteFrame, screenFrames: screenFrames)
        let available = targetScreen.insetBy(dx: 8, dy: 8)
        guard available.width > 0, available.height > 0 else {
            return NSRect(origin: targetScreen.origin, size: minimumSize)
        }

        // 窗口比屏幕还大时收缩到可用区域，保证标题栏和内容都能操作。
        let width = min(max(finiteFrame.width, minimumSize.width), available.width)
        let height = min(max(finiteFrame.height, minimumSize.height), available.height)

        let x = min(max(finiteFrame.origin.x, available.minX), available.maxX - width)
        let y = min(max(finiteFrame.origin.y, available.minY), available.maxY - height)

        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func adjustedForCurrentScreens(_ frame: NSRect) -> NSRect {
        adjustedFrame(frame, screenFrames: NSScreen.screens.map(\.visibleFrame))
    }

    static func defaultFrame(existingWindowCount: Int) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = min(900, visible.width)
        let height = min(600, visible.height)
        let step = CGFloat(existingWindowCount % 6) * 26
        let origin = CGPoint(
            x: visible.midX - width / 2 + step,
            y: visible.midY - height / 2 - step
        )
        return adjustedFrame(
            NSRect(origin: origin, size: NSSize(width: width, height: height)),
            screenFrames: [visible],
            minimumSize: NSSize(width: min(minimumSize.width, width), height: min(minimumSize.height, height))
        )
    }

    private static func bestScreen(for frame: NSRect, screenFrames: [NSRect]) -> NSRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)

        if let containing = screenFrames.first(where: { $0.contains(center) }) {
            return containing
        }

        let withIntersection = screenFrames.max {
            intersectionArea($0, frame) < intersectionArea($1, frame)
        }

        if let withIntersection, intersectionArea(withIntersection, frame) > 0 {
            return withIntersection
        }

        // 完全离屏时选中心距离最近的屏幕
        return screenFrames.min {
            distanceSquared(from: $0.center, to: center) < distanceSquared(from: $1.center, to: center)
        } ?? screenFrames[0]
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private extension NSRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
