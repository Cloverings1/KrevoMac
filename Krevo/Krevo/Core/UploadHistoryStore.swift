import Foundation
import os

// MARK: - Persisted entry

struct HistoryEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let shareURL: String?
    let completionTime: Date
    let fileId: String
}

// MARK: - Actor — owns all disk I/O for upload history

actor UploadHistoryStore {

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("io.krevo.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("upload-history.json")
    }

    /// Load all persisted entries. Returns [] on first launch or corrupt file.
    func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([HistoryEntry].self, from: data) else {
            KrevoConstants.logger.warning("UploadHistoryStore: corrupt history file — discarding")
            return []
        }
        return entries
    }

    /// Append a new entry and persist. Trims oldest entries beyond maxHistoryCount.
    func append(_ entry: HistoryEntry) {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > KrevoConstants.maxHistoryCount {
            entries = Array(entries.prefix(KrevoConstants.maxHistoryCount))
        }
        write(entries)
    }

    /// Remove all persisted history (called on sign-out).
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func write(_ entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else {
            KrevoConstants.logger.error("UploadHistoryStore: failed to encode history")
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
