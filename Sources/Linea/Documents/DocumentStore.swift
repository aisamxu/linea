import Foundation

enum DocumentStoreError: LocalizedError, Equatable {
    case fileMissing(String)
    case unreadable(String)
    case invalidUTF8(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .fileMissing(name):
            return "The file “\(name)” could not be found."
        case let .unreadable(message):
            return "The file could not be read: \(message)"
        case let .invalidUTF8(name):
            return "“\(name)” is not valid UTF-8 text."
        case let .writeFailed(message):
            return "The file could not be saved: \(message)"
        }
    }
}

/// 首版只处理 UTF-8 纯文本；所有写入都使用原子替换，避免写一半留下损坏文件。
enum DocumentStore {
    static func readText(from url: URL) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw DocumentStoreError.fileMissing(url.lastPathComponent)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DocumentStoreError.unreadable(error.localizedDescription)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentStoreError.invalidUTF8(url.lastPathComponent)
        }

        return text
    }

    static func writeText(_ text: String, to url: URL) throws {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw DocumentStoreError.writeFailed(error.localizedDescription)
        }
    }

    static func currentSignature(of url: URL) -> FileSignature? {
        FileSignature.current(for: url)
    }
}
