import Foundation

/// Rolling record of recent dictations, so nothing is lost when a paste lands
/// somewhere unexpected. Stored as plain JSON in ~/.config/murmur/history.json
/// and pruned by age on every write.
struct HistoryEntry: Codable {
    let timestamp: Date
    let text: String
    let language: String
    let duration: Double
}

enum History {

    static var fileURL: URL { Paths.configDir.appendingPathComponent("history.json") }
    /// Human-readable dump produced on demand for "Show History".
    static var readableURL: URL { Paths.configDir.appendingPathComponent("history.txt") }

    private static let lock = NSLock()

    static func load() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    private static func loadUnlocked() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Appends an entry and prunes. Newest first in the stored array.
    static func add(text: String, language: String, duration: Double, config: HistoryConfig) {
        guard config.enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock(); defer { lock.unlock() }
        var entries = loadUnlocked()
        entries.insert(HistoryEntry(timestamp: Date(), text: trimmed,
                                    language: language, duration: duration),
                       at: 0)
        entries = prune(entries, config: config)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func prune(_ entries: [HistoryEntry], config: HistoryConfig) -> [HistoryEntry] {
        let cutoff = Date().addingTimeInterval(-config.retention_hours * 3600)
        return Array(entries.filter { $0.timestamp >= cutoff }.prefix(config.max_entries))
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: readableURL)
    }

    /// Renders the current history to a readable text file and returns its URL.
    @discardableResult
    static func writeReadable(config: HistoryConfig) -> URL {
        let entries = prune(load(), config: config)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var out = """
        Murmur — historial de dictado
        Guardando las últimas \(Int(config.retention_hours)) horas · \(entries.count) entradas
        ================================================================

        """
        if entries.isEmpty {
            out += "\n(todavía no hay dictados en la ventana de retención)\n"
        }
        for e in entries {
            out += "\n[\(df.string(from: e.timestamp))]  \(e.language)  \(String(format: "%.1fs", e.duration))\n"
            out += e.text + "\n"
            out += "----------------------------------------------------------------\n"
        }
        try? out.write(to: readableURL, atomically: true, encoding: .utf8)
        return readableURL
    }
}
