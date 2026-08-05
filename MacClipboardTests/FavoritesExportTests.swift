import AppKit
import XCTest
@testable import MacClipboard

/// Covers the on-disk shape of an export, since that shape is what any future importer, and any
/// user reading the JSON by hand, will depend on.
final class FavoritesExportTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func snapshot(
        type: ClipboardContentType,
        note: String? = nil,
        isSensitive: Bool = false,
        text: String? = nil,
        imageData: Data? = nil,
        fileURLs: [URL] = []
    ) -> PersistenceManager.FavoriteSnapshot {
        PersistenceManager.FavoriteSnapshot(
            id: UUID(),
            type: type,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            note: note,
            isSensitive: isSensitive,
            text: text,
            imageData: imageData,
            fileURLs: fileURLs
        )
    }

    private func tiffData(width: Int = 4, height: Int = 3) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.tiffRepresentation)
    }

    /// Expands the archive and returns the decoded JSON plus the folder it came from.
    private func export(
        _ favorites: [PersistenceManager.FavoriteSnapshot]
    ) throws -> (json: [String: Any], root: URL, exportedCount: Int) {
        let destination = workspace.appendingPathComponent("MacClipboard-Favorites-2026-08-05.zip")
        let count = try FavoritesExport.write(favorites, to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "no archive written")

        let expanded = workspace.appendingPathComponent("expanded", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", destination.path, expanded.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "archive could not be expanded")

        // The archive carries a single top-level folder named after the chosen file.
        let root = expanded.appendingPathComponent("MacClipboard-Favorites-2026-08-05", isDirectory: true)
        let data = try Data(contentsOf: root.appendingPathComponent("favorites.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json, root, count)
    }

    private func entries(in json: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(json["favorites"] as? [[String: Any]])
    }

    // MARK: - Tests

    func testExportingNothingThrowsRatherThanWritingAnEmptyArchive() {
        let destination = workspace.appendingPathComponent("empty.zip")

        XCTAssertThrowsError(try FavoritesExport.write([], to: destination)) { error in
            XCTAssertEqual(error as? FavoritesExport.Failure, .nothingToExport)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testArchiveCarriesVersionAndCount() throws {
        let result = try export([
            snapshot(type: .text, text: "first"),
            snapshot(type: .text, text: "second"),
        ])

        XCTAssertEqual(result.exportedCount, 2)
        XCTAssertEqual(result.json["app"] as? String, "MacClipboard")
        XCTAssertEqual(result.json["formatVersion"] as? Int, FavoritesExport.formatVersion)
        XCTAssertEqual(result.json["count"] as? Int, 2)
        XCTAssertNotNil(result.json["exportedAt"] as? String)
        XCTAssertEqual(try entries(in: result.json).count, 2)
    }

    func testTextFavoriteCarriesItsTextAndNoImageKey() throws {
        let result = try export([snapshot(type: .text, note: "a note", text: "hello")])
        let entry = try XCTUnwrap(try entries(in: result.json).first)

        XCTAssertEqual(entry["type"] as? String, "text")
        XCTAssertEqual(entry["text"] as? String, "hello")
        XCTAssertEqual(entry["note"] as? String, "a note")
        XCTAssertNil(entry["image"], "a text favorite should not reference an image")
        XCTAssertNil(entry["files"])
    }

    func testImageFavoriteIsWrittenAsPngAndReferencedRelatively() throws {
        let favorite = snapshot(type: .image, text: "alt text", imageData: try tiffData())
        let result = try export([favorite])
        let entry = try XCTUnwrap(try entries(in: result.json).first)

        XCTAssertEqual(entry["type"] as? String, "image")
        XCTAssertEqual(entry["image"] as? String, "images/\(favorite.id.uuidString).png")
        // Mixed image-and-text payloads keep their text representation.
        XCTAssertEqual(entry["text"] as? String, "alt text")

        let imageURL = result.root.appendingPathComponent("images/\(favorite.id.uuidString).png")
        let written = try Data(contentsOf: imageURL)
        XCTAssertNotNil(NSImage(data: written), "the exported image does not decode")
        // PNG magic number, so we know it was re-encoded rather than copied as TIFF.
        XCTAssertEqual(Array(written.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testTextOnlyExportHasNoImagesFolder() throws {
        let result = try export([snapshot(type: .text, text: "only text")])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: result.root.appendingPathComponent("images").path),
            "an images folder should only appear when there are images to put in it"
        )
    }

    func testHiddenFavoritesAreExportedButFlagged() throws {
        let result = try export([
            snapshot(type: .text, isSensitive: true, text: "secret"),
            snapshot(type: .text, isSensitive: false, text: "ordinary"),
        ])
        let exported = try entries(in: result.json)

        let hidden = try XCTUnwrap(exported.first { $0["text"] as? String == "secret" })
        XCTAssertEqual(hidden["sensitive"] as? Bool, true)

        let ordinary = try XCTUnwrap(exported.first { $0["text"] as? String == "ordinary" })
        XCTAssertNil(ordinary["sensitive"], "only hidden items should carry the flag")
    }

    func testFileFavoriteCarriesItsPaths() throws {
        let result = try export([
            snapshot(type: .file, fileURLs: [
                URL(fileURLWithPath: "/tmp/one.txt"),
                URL(fileURLWithPath: "/tmp/two.txt"),
            ])
        ])
        let entry = try XCTUnwrap(try entries(in: result.json).first)

        XCTAssertEqual(entry["type"] as? String, "files")
        XCTAssertEqual(entry["files"] as? [String], ["/tmp/one.txt", "/tmp/two.txt"])
        XCTAssertNil(entry["text"])
    }

    func testUndecodableImageStillGetsAnEntry() throws {
        let result = try export([snapshot(type: .image, imageData: Data([0x00, 0x01, 0x02]))])
        let entry = try XCTUnwrap(try entries(in: result.json).first)

        XCTAssertEqual(result.json["count"] as? Int, 1, "the item must not be dropped silently")
        XCTAssertNil(entry["image"])
    }

    // MARK: - Storage encoding

    /// The reason images get their own retention window in the first place: uncompressed TIFF is
    /// what made a history cost a gigabyte.
    func testStoredImagesAreEncodedAsPngAndAreMuchSmallerThanTiff() throws {
        // Photographic-ish content, so the win is not an artifact of a flat test colour.
        let size = 220
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        for x in stride(from: 0, to: size, by: 2) {
            for y in stride(from: 0, to: size, by: 2) {
                NSColor(
                    calibratedHue: CGFloat(x) / CGFloat(size),
                    saturation: 0.8,
                    brightness: CGFloat(y) / CGFloat(size),
                    alpha: 1
                ).setFill()
                NSRect(x: x, y: y, width: 2, height: 2).fill()
            }
        }
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let stored = try XCTUnwrap(image.clipboardStorageData)

        XCTAssertTrue(stored.isPNGEncoded, "clipboard images should be stored as PNG")
        XCTAssertFalse(tiff.isPNGEncoded)
        XCTAssertLessThan(stored.count, tiff.count, "PNG storage should be smaller than TIFF")
        XCTAssertNotNil(NSImage(data: stored), "stored bytes must still decode as an image")
    }

    func testPngEncodingIsIdempotentAndRejectsNonImages() throws {
        let image = NSImage(size: NSSize(width: 6, height: 6))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 6, height: 6).fill()
        image.unlockFocus()

        let stored = try XCTUnwrap(image.clipboardStorageData)
        let again = try XCTUnwrap(Data.pngEncoded(from: stored))
        XCTAssertTrue(again.isPNGEncoded, "re-encoding PNG should stay PNG")

        XCTAssertNil(Data.pngEncoded(from: Data([0x00, 0x01, 0x02])), "garbage must not encode")
    }

    // MARK: - Cleanup scope

    func testCleanupScopePredicateTargetsImagesOnly() {
        XCTAssertNil(PersistenceManager.CleanupScope.everything.predicate)

        let images = PersistenceManager.CleanupScope.images.predicate
        XCTAssertEqual(
            images?.predicateFormat,
            NSPredicate(format: "contentType == %d", ClipboardContentType.image.rawValue).predicateFormat,
            "image cleanup must not reach text or file items"
        )
    }

    func testSuggestedFileNameSortsChronologically() {
        let name = FavoritesExport.suggestedFileName(date: Date(timeIntervalSince1970: 1_770_000_000))
        XCTAssertTrue(name.hasSuffix(".zip"))
        XCTAssertTrue(name.hasPrefix("MacClipboard-Favorites-2026-"), "unexpected name: \(name)")
    }
}
