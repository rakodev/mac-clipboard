import AppKit
import Vision

/// Reading the text in a copied image, on this Mac, when the user asks for it.
///
/// The same model as the editor, Copy Merged and Split: the image row is never touched and the text
/// lands as an ordinary new item, so history stays a log of what was on the pasteboard plus the
/// items the user deliberately made. The text is deliberately *not* put into the image's
/// `associatedText`: as an item of its own it is searchable, editable, persistable and deletable
/// like anything else, and the image row keeps meaning "what was on the pasteboard".
///
/// Nothing here runs on capture, and that is the whole shape of the feature. Recognising every
/// screenshot would spend CPU and battery on images that are mostly pasted once and forgotten, and
/// the storage note in `CLAUDE.md` says how many images a real history holds.
struct ClipboardImageTextRecognition {

    /// One line as Vision reported it, with the box that says where it was.
    struct RecognizedLine: Equatable {
        let text: String
        /// Normalised to the image, origin at the bottom left, as `VNRecognizedTextObservation`
        /// reports it.
        let boundingBox: CGRect
    }

    /// What recognising the selected item would do, worked out before anything is read so the
    /// action can be offered, or refused, without touching an image.
    struct Plan: Equatable {
        /// The item the text will be read from, held as an id rather than as an `NSImage`: an image
        /// beyond the newest few is not in memory at all (`ClipboardItem.needsImageLoad`), and the
        /// popover asks for this on every rebuild.
        let itemId: UUID
        /// Whether the source image is masked. The result inherits it, so masking can only be
        /// gained, exactly as in the editor, Copy Merged and Split.
        let sourceIsSensitive: Bool
    }

    /// Nil for anything that is not an image, and for an image that is still masked.
    ///
    /// `isRevealed` is the test the editor makes for the same reason (`canEditSelectedItem`):
    /// recognising a masked image would write a new row holding text the user never got to read,
    /// out of a clip they asked to keep hidden.
    static func plan(for item: ClipboardItem?, isRevealed: Bool) -> Plan? {
        guard let item, item.type == .image else { return nil }
        guard !item.isSensitive || isRevealed else { return nil }

        return Plan(itemId: item.id, sourceIsSensitive: item.isSensitive)
    }

    /// How much two boxes have to overlap vertically to count as the same line of text.
    ///
    /// A fraction of the shorter box rather than a distance, because the boxes are normalised to the
    /// image: a fixed number would mean something different for every screenshot.
    private static let sameLineOverlapFraction = 0.5

    /// The recognised lines as one clip, in reading order.
    ///
    /// Vision's result order is not documented as reading order, and here the order *is* the output,
    /// so it is put back together explicitly: top to bottom, and left to right within a line. Two
    /// boxes on one line become one line joined with a space, which is what a sentence broken into
    /// two observations needs and the least wrong thing for a row of table cells.
    static func text(from lines: [RecognizedLine]) -> String {
        // A box holding nothing but whitespace is dropped by the rule Split drops a blank line by:
        // it would contribute a line of the clip that shows nothing.
        let carrying = lines.filter { $0.text.contains(where: { !$0.isWhitespace }) }

        // A total order first, so the grouping below never depends on the order Vision happened to
        // return. Asking "same line?" from inside the comparator would not be transitive, and a
        // comparator that is not an ordering is a sort with no defined result.
        let topToBottom = carrying.sorted {
            if $0.boundingBox.midY != $1.boundingBox.midY {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        var rows: [[RecognizedLine]] = []
        for line in topToBottom {
            // Compared against the row's first box, never its last: chaining the comparison would
            // let a column of slightly descending boxes drift into one very tall line.
            if let first = rows.last?.first, sharesLine(first, line) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        return rows
            .map { row in
                row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    private static func sharesLine(_ lhs: RecognizedLine, _ rhs: RecognizedLine) -> Bool {
        let overlap = min(lhs.boundingBox.maxY, rhs.boundingBox.maxY)
            - max(lhs.boundingBox.minY, rhs.boundingBox.minY)
        let shorter = min(lhs.boundingBox.height, rhs.boundingBox.height)

        guard shorter > 0 else { return false }
        return overlap > sameLineOverlapFraction * shorter
    }

    /// Builds the new item.
    ///
    /// Masking can only be gained, as in the editor, Copy Merged and Split: `sensitivity` is the
    /// policy's verdict on the recognised text, or-ed with the source image's own flag, so text read
    /// out of a hidden image is hidden too. Favorite and note are not inherited: this is not the
    /// item the user starred, and the note field is theirs to write in, which is why the item says
    /// it is derived through `isRecognizedText` and not through a note put there on its behalf.
    ///
    /// Nothing is trimmed, as everywhere else: whitespace in a clip is content.
    static func recognizedItem(
        from plan: Plan,
        text: String,
        sensitivity: ClipboardSensitivityFlags,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            content: text,
            type: .text,
            timestamp: timestamp,
            isFavorite: false,
            isSensitive: sensitivity.isSensitive || plan.sourceIsSensitive,
            isAutoSensitive: sensitivity.isAutoSensitive,
            isPasswordLike: sensitivity.isPasswordLike,
            isManuallyUnsensitive: false,
            note: nil,
            isRecognizedText: true
        )
    }
}

/// What `ClipboardMonitor.recognizeText` actually did.
///
/// `noTextFound` is a case of its own rather than a failure: an image with nothing readable in it is
/// the ordinary outcome for a photo or a diagram, and the popover has to be able to say so without
/// making it sound as though the recognition broke.
enum ClipboardImageTextRecognitionOutcome: Equatable {
    case recognized(id: UUID, lineCount: Int)
    /// The recognised text was already the clip at the top of the history, or matched one further
    /// down which moved up to take its place. Nothing was added a second time.
    case alreadyInHistory(id: UUID)
    case noTextFound
    case failed
}

/// The recognition itself, behind a protocol so the value-level rules above can be tested without
/// Vision and without a fixture image that happens to contain legible text.
protocol ImageTextRecognizing {
    /// Never does the work on the caller's thread. The completion is called on the main queue.
    func recognizeText(
        in image: NSImage,
        completion: @escaping (Result<[ClipboardImageTextRecognition.RecognizedLine], Error>) -> Void
    )
}

/// Vision's on-device text recognition.
///
/// `VNRecognizeTextRequest` runs locally, needs no entitlement and sends nothing anywhere, which is
/// what lets an app whose whole claim is that your clipboard history stays on your own Mac offer
/// this at all. The update check remains the only thing the app does over the network unasked; see
/// `UpdateService`.
struct VisionImageTextRecognizer: ImageTextRecognizing {
    enum Failure: LocalizedError {
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                return "The image could not be read."
            }
        }
    }

    func recognizeText(
        in image: NSImage,
        completion: @escaping (Result<[ClipboardImageTextRecognition.RecognizedLine], Error>) -> Void
    ) {
        // Done here rather than on the background queue: an `NSImage` is not safe to hand to another
        // thread, and a `CGImage` is. It is also the one failure that is not Vision's.
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            DispatchQueue.main.async { completion(.failure(Failure.unreadableImage)) }
            return
        }

        // Off the main thread without exception: an accurate pass over a full-screen screenshot is
        // hundreds of milliseconds, and the popover is on screen the whole time.
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // The alternative is naming a language list, which would read the wrong language for
            // everyone it left out.
            request.automaticallyDetectsLanguage = true

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

                let lines = (request.results ?? []).compactMap { observation -> ClipboardImageTextRecognition.RecognizedLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return ClipboardImageTextRecognition.RecognizedLine(
                        text: candidate.string,
                        boundingBox: observation.boundingBox
                    )
                }
                DispatchQueue.main.async { completion(.success(lines)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
