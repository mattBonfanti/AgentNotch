import Foundation

/// Incremental line reader for append-only JSONL transcripts.
/// Remembers how far it got in each file so each poll only parses what is new.
final class JSONLTailer {
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64
        var partial: Data
    }

    private var cursors: [String: Cursor] = [:]

    func forget(paths: Set<String>) {
        for key in cursors.keys where !paths.contains(key) { cursors[key] = nil }
    }

    /// Returns the JSON objects appended since the previous call.
    /// `isFirstRead` tells the caller it is seeing the whole file, so cumulative
    /// counters can be reset instead of double-counted.
    func newObjects(at path: String) -> (objects: [[String: Any]], isFirstRead: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return ([], false) }

        var cursor = cursors[path] ?? Cursor(inode: inode, offset: 0, partial: Data())
        var fresh = cursors[path] == nil
        // File replaced or truncated (compaction, rotation) — start over.
        if cursor.inode != inode || size < cursor.offset {
            cursor = Cursor(inode: inode, offset: 0, partial: Data())
            fresh = true
        }
        guard size > cursor.offset else {
            cursors[path] = cursor
            return ([], false)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], false) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
        } catch { return ([], false) }
        let chunk = handle.readDataToEndOfFile()
        cursor.offset += UInt64(chunk.count)

        var buffer = cursor.partial + chunk
        var objects: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = buffer[buffer.index(after: nl)...]
            if line.count > 1,
               let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                objects.append(obj)
            }
        }
        cursor.partial = Data(buffer)
        cursors[path] = cursor
        return (objects, fresh)
    }
}

// MARK: - Forgiving JSON access

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func dbl(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func arr(_ k: String) -> [[String: Any]]? { self[k] as? [[String: Any]] }

    /// Dotted lookup: obj.path("info.total_token_usage.total_tokens")
    func path(_ keyPath: String) -> Any? {
        var node: Any? = self
        for part in keyPath.split(separator: ".") {
            guard let d = node as? [String: Any] else { return nil }
            node = d[String(part)]
        }
        return node
    }
    func pathInt(_ keyPath: String) -> Int? { (path(keyPath) as? NSNumber)?.intValue }
    func pathStr(_ keyPath: String) -> String? { path(keyPath) as? String }
    func pathDbl(_ keyPath: String) -> Double? { (path(keyPath) as? NSNumber)?.doubleValue }
}

enum TS {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func fromMillis(_ ms: Int?) -> Date? {
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
