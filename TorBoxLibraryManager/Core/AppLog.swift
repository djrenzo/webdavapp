import Foundation

/// The last 200 log lines, credentials redacted (§11 Privacy, §9.7 Diagnostics).
enum AppLog {
    private static let buffer = LogBuffer()
    private static let userInfo = Pattern(#"(://)[^/@\s:]*:[^/@\s]*@"#)
    private static let bearer = Pattern(#"(?i)(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#)

    static func redact(_ text: String) -> String {
        bearer.replace(in: userInfo.replace(in: text, with: "://***:***@"), with: "<redacted>")
    }

    static func write(_ message: String) {
        let line = "\(timestamp()) \(redact(message))"
        buffer.append(line)
        #if DEBUG
        print(line)
        #endif
    }

    static func lines() -> [String] {
        buffer.snapshot()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
