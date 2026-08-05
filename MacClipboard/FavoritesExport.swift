import AppKit
import Foundation
import UniformTypeIdentifiers

/// Writes the user's favorites out as a single archive containing `favorites.json` and, when
/// there are image favorites, an `images/` folder beside it.
///
/// An archive rather than one JSON file, because images are stored as TIFF and run to megabytes
/// each: base64 inside the JSON would add a third on top and produce a file no editor will open.
/// Keeping the pictures alongside as PNGs leaves the JSON readable and the images openable by
/// double-click. Always an archive, even for text-only favorites, so there is a single output
/// shape to describe and a single path to maintain.
///
/// `formatVersion` is written so an importer can be added later without guessing.
enum FavoritesExport {
    static let formatVersion = 1

    enum Failure: LocalizedError, Equatable {
        case nothingToExport
        case archiveFailed

        var errorDescription: String? {
            switch self {
            case .nothingToExport:
                return L10n.string("There are no favorites to export.", comment: "Export error message")
            case .archiveFailed:
                return L10n.string("The archive could not be created.", comment: "Export error message")
            }
        }
    }

    /// e.g. `MacClipboard-Favorites-2026-08-05.zip`. Sorts chronologically in Finder.
    static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "MacClipboard-Favorites-\(formatter.string(from: date)).zip"
    }

    /// Writes `favorites` to `destination`, returning the number of items exported.
    @discardableResult
    static func write(_ favorites: [PersistenceManager.FavoriteSnapshot], to destination: URL) throws -> Int {
        guard !favorites.isEmpty else { throw Failure.nothingToExport }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("FavoritesExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }

        // The archive takes its top-level folder name from this directory, so name it after the
        // file the user chose: expanding the zip then gives them a folder they can recognise.
        let root = workspace.appendingPathComponent(
            destination.deletingPathExtension().lastPathComponent,
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var entries: [Entry] = []
        var hasImagesDirectory = false

        for favorite in favorites {
            let identifier = favorite.id.uuidString
            var imagePath: String?
            var files: [String]?
            var text: String?

            switch favorite.type {
            case .text:
                text = favorite.text ?? ""

            case .image:
                // Images carry an optional text representation for mixed payloads; keep it.
                text = favorite.text
                if let stored = favorite.imageData, let png = pngData(from: stored) {
                    if !hasImagesDirectory {
                        try fileManager.createDirectory(
                            at: root.appendingPathComponent("images", isDirectory: true),
                            withIntermediateDirectories: true
                        )
                        hasImagesDirectory = true
                    }
                    let relative = "images/\(identifier).png"
                    try png.write(to: root.appendingPathComponent(relative))
                    imagePath = relative
                }
                // An image whose data will not decode still gets an entry, with no `image` key.
                // Dropping it silently would make the export quietly incomplete.

            case .file:
                files = favorite.fileURLs.map(\.path)
            }

            entries.append(
                Entry(
                    id: identifier,
                    type: favorite.type.exportName,
                    createdAt: favorite.createdAt,
                    note: favorite.note?.isEmpty == true ? nil : favorite.note,
                    sensitive: favorite.isSensitive ? true : nil,
                    text: text,
                    image: imagePath,
                    files: files
                )
            )
        }

        let payload = Payload(
            formatVersion: formatVersion,
            exportedAt: Date(),
            count: entries.count,
            favorites: entries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: root.appendingPathComponent("favorites.json"))

        try archive(directory: root, to: destination)
        return entries.count
    }

    // MARK: - JSON shape

    private struct Payload: Encodable {
        let app = "MacClipboard"
        let formatVersion: Int
        let exportedAt: Date
        let count: Int
        let favorites: [Entry]
    }

    /// `nil` fields are omitted by `JSONEncoder`, so each entry carries only the keys that apply
    /// to its type.
    private struct Entry: Encodable {
        let id: String
        let type: String
        let createdAt: Date
        let note: String?
        let sensitive: Bool?
        let text: String?
        let image: String?
        let files: [String]?
    }

    // MARK: - Encoding

    /// Stored images are PNG already, but older ones may still be TIFF, so normalise on the way
    /// out: an export should not hand someone a 16 MB file where 200 KB carries the same pixels.
    private static func pngData(from stored: Data) -> Data? {
        stored.isPNGEncoded ? stored : Data.pngEncoded(from: stored)
    }

    /// Zips `directory` using `NSFileCoordinator`'s upload coordination, which is the one way to
    /// produce an archive from Foundation alone, with no external tool and no dependency.
    private static func archive(directory: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var coordinatorError: NSError?
        var writeResult: Result<Void, Error>?

        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinatorError
        ) { archiveURL in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: archiveURL, to: destination)
                writeResult = .success(())
            } catch {
                writeResult = .failure(error)
            }
        }

        if let coordinatorError { throw coordinatorError }
        guard let writeResult else { throw Failure.archiveFailed }
        try writeResult.get()
    }
}

private extension ClipboardContentType {
    /// Stable strings for the export format, independent of the internal raw values.
    var exportName: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .file: return "files"
        }
    }
}
