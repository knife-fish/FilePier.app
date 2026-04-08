import Foundation

protocol SiteUsageStore {
    func loadUsage() throws -> [UUID: SiteUsageRecord]
    func saveUsage(_ usage: [UUID: SiteUsageRecord]) throws
}

struct SiteUsageRecord: Codable, Equatable {
    var lastConnectedAt: Date
    var lastConnectionSummary: String
}

struct JSONSiteUsageStore: SiteUsageStore {
    let fileURL: URL

    init(fileURL: URL = JSONSiteUsageStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func loadUsage() throws -> [UUID: SiteUsageRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try Dictionary(
            uniqueKeysWithValues: decoder.decode([StoredSiteUsageRecord].self, from: data).map {
                ($0.id, $0.record)
            }
        )
    }

    func saveUsage(_ usage: [UUID: SiteUsageRecord]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let records = usage
            .map(StoredSiteUsageRecord.init)
            .sorted { lhs, rhs in
                lhs.record.lastConnectedAt > rhs.record.lastConnectedAt
            }
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent("FilePier", isDirectory: true)
            .appendingPathComponent("SiteUsage.json", isDirectory: false)
    }
}

private struct StoredSiteUsageRecord: Codable {
    let id: UUID
    let lastConnectedAt: Date
    let lastConnectionSummary: String

    init(id: UUID, record: SiteUsageRecord) {
        self.id = id
        self.lastConnectedAt = record.lastConnectedAt
        self.lastConnectionSummary = record.lastConnectionSummary
    }

    nonisolated init(_ entry: (key: UUID, value: SiteUsageRecord)) {
        self.id = entry.key
        self.lastConnectedAt = entry.value.lastConnectedAt
        self.lastConnectionSummary = entry.value.lastConnectionSummary
    }

    var record: SiteUsageRecord {
        SiteUsageRecord(
            lastConnectedAt: lastConnectedAt,
            lastConnectionSummary: lastConnectionSummary
        )
    }
}
