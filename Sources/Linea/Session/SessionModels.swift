import Foundation

/// 会话清单。清单只记录元数据和草稿文件名，全文永远只放在草稿文件里。
struct SessionManifest: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var sessionID: UUID
    var createdAt: Date
    var windows: [WindowSnapshot]
}

struct WindowSnapshot: Codable, Equatable {
    var frame: WindowFrame
    var isActive: Bool
    var selectedTabIndex: Int
    var tabs: [TabSnapshot]
}

struct WindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: NSRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var rect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

struct TabSnapshot: Codable, Equatable {
    var id: UUID
    var filePath: String?
    var displayName: String
    var isDirty: Bool
    var draftFileName: String?
    var fileSignature: FileSignature?
    var selections: [SelectionSnapshot]
    var scrollOrigin: ScrollOrigin
}

struct SelectionSnapshot: Codable, Equatable {
    var location: Int
    var length: Int

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    init(_ range: NSRange) {
        location = range.location
        length = range.length
    }

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

struct ScrollOrigin: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var point: CGPoint {
        CGPoint(x: x, y: y)
    }
}
