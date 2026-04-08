import Foundation

struct FavoritePlaceRecord: Codable, Equatable {
    let path: String
    let customTitle: String?

    init(url: URL, customTitle: String? = nil) {
        self.path = url.standardizedFileURL.path(percentEncoded: false)
        self.customTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var url: URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }
}

protocol FavoritePlaceStore {
    func loadFavoritePlaces() throws -> [FavoritePlaceRecord]
    func saveFavoritePlaces(_ favorites: [FavoritePlaceRecord]) throws
}

struct JSONFavoritePlaceStore: FavoritePlaceStore {
    let fileURL: URL

    init(fileURL: URL = JSONFavoritePlaceStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func loadFavoritePlaces() throws -> [FavoritePlaceRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode([FavoritePlaceRecord].self, from: data)
    }

    func saveFavoritePlaces(_ favorites: [FavoritePlaceRecord]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(favorites)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent("FilePier", isDirectory: true)
            .appendingPathComponent("FavoritePlaces.json", isDirectory: false)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
