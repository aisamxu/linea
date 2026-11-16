import Foundation

/// 文件在某个时刻的轻量签名。
///
/// 只记录大小和修改时间，用来判断一个已打开的文件是否被其他程序改过，
/// 不读取文件内容，也不会在编辑期间触发任何磁盘写入。
struct FileSignature: Codable, Equatable {
    let size: Int64
    let modificationTime: TimeInterval

    init(size: Int64, modificationTime: TimeInterval) {
        self.size = size
        // 统一到毫秒，避免 JSON 往返和文件系统精度差异造成“伪外部修改”
        self.modificationTime = (modificationTime * 1000).rounded() / 1000
    }

    /// 读取磁盘上的当前签名；文件不存在或无法读取时返回 nil。
    static func current(for url: URL) -> FileSignature? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return nil
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date
        else {
            return nil
        }

        return FileSignature(
            size: size.int64Value,
            modificationTime: modificationDate.timeIntervalSince1970
        )
    }
}
