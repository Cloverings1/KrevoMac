import Foundation
import os

// MARK: - Persisted entry

enum HistoryResult: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

struct HistoryEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let shareURL: String?
    let completionTime: Date
    let fileId: String?
    let result: HistoryResult
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case fileSize
        case shareURL
        case completionTime
        case fileId
        case result
        case message
    }

    init(
        id: UUID,
        fileName: String,
        fileSize: Int64,
        shareURL: String?,
        completionTime: Date,
        fileId: String?,
        result: HistoryResult,
        message: String?
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.shareURL = shareURL
        self.completionTime = completionTime
        self.fileId = fileId
        self.result = result
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        shareURL = try container.decodeIfPresent(String.self, forKey: .shareURL)
        completionTime = try container.decode(Date.self, forKey: .completionTime)
        fileId = try container.decodeIfPresent(String.self, forKey: .fileId)
        result = try container.decodeIfPresent(HistoryResult.self, forKey: .result) ?? .completed
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
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
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > KrevoConstants.maxHistoryCount {
            entries = Array(entries.prefix(KrevoConstants.maxHistoryCount))
        }
        write(entries)
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let entries = load().filter { !ids.contains($0.id) }
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
