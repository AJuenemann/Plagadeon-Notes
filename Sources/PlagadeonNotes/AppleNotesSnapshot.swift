import Foundation
import SQLite3
import zlib
import AppKit
import CryptoKit

enum SQLiteTableRole: String, Codable {
    case note
    case folder
    case attachment
    case unknown
}

struct SQLiteTable: Identifiable, Codable {
    let id: String
    let name: String
    let sql: String
    let columns: [String]
    let rowCount: Int
    let role: SQLiteTableRole
}

struct SQLiteInspection: Codable {
    let file: String
    let tables: [SQLiteTable]
}

enum SnapshotContentBlock: Equatable {
    case text(String)
    case attachment(sourceKey: String)
}

struct SnapshotAttachmentSource {
    let sourceKey: String
    let identifier: String?
    let mediaIdentifier: String?
    let filename: String
    let fileURL: URL
}

struct SnapshotNoteCandidate {
    let title: String
    let body: String
    let folder: String
    let attachmentSources: [SnapshotAttachmentSource]
    let contentBlocks: [SnapshotContentBlock]
    let modifiedAt: Date
    let sourceID: String
}

struct SnapshotImportReport {
    let candidates: Int
    let imported: Int
    let updated: Int
    let duplicates: Int
    let unresolvedAttachments: Int
}

struct ProtobufField: Equatable {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed32(Data)
        case fixed64(Data)
        case lengthDelimited(Data)
    }

    let number: Int
    let value: Value
}

enum AppleNotesSnapshotInspector {
    static func inspect(_ folder: URL) -> [SQLiteInspection] {
        let files = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        return files
            .filter { ["sqlite", "db"].contains($0.pathExtension.lowercased()) }
            .compactMap(inspectDatabase)
    }

    static func noteCandidates(in folder: URL) -> [SnapshotNoteCandidate] {
        // First check for modern Apple Notes NoteStore.sqlite
        let noteStoreURL = folder.appendingPathComponent("NoteStore.sqlite")
        if FileManager.default.fileExists(atPath: noteStoreURL.path) {
            let modernNotes = readModernAppleNotes(from: noteStoreURL, baseFolder: folder)
            if !modernNotes.isEmpty {
                return modernNotes
            }
        }

        // Search for any sqlite file with NoteStore in name
        let files = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        for file in files where file.lastPathComponent.lowercased().contains("notestore") && file.pathExtension.lowercased() == "sqlite" {
            let notes = readModernAppleNotes(from: file, baseFolder: folder)
            if !notes.isEmpty {
                return notes
            }
        }

        // Generic fallback for simple SQLite schemas
        return files
            .filter { ["sqlite", "db"].contains($0.pathExtension.lowercased()) }
            .flatMap(readGenericNoteCandidates(from:))
    }

    // MARK: - Modern Apple Notes CoreData Parser

    static func readModernAppleNotes(from dbURL: URL, baseFolder: URL) -> [SnapshotNoteCandidate] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(database) }

        // 1. Read folders (Z_ENT = 15 in ZICCLOUDSYNCINGOBJECT)
        var folders: [Int64: String] = [:]
        var statement: OpaquePointer?
        let folderQuery = "SELECT Z_PK, ZTITLE2, ZNAME FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = 15;"
        if sqlite3_prepare_v2(database, folderQuery, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let pk = sqlite3_column_int64(statement, 0)
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                    ?? sqlite3_column_text(statement, 2).map { String(cString: $0) }
                    ?? "Notizen"
                folders[pk] = title
            }
            sqlite3_finalize(statement)
        }

        // 2. Read attachments mapped to note PK (Z_ENT = 5 for ICAttachment, ZMEDIA -> ICMedia)
        var noteAttachments: [Int64: [SnapshotAttachmentSource]] = [:]
        let attachQuery = """
        SELECT a.ZNOTE, a.ZIDENTIFIER, a.ZFILENAME, m.ZIDENTIFIER, m.ZFILENAME, a.Z_PK
        FROM ZICCLOUDSYNCINGOBJECT a
        LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON a.ZMEDIA = m.Z_PK
        WHERE a.Z_ENT = 5
        ORDER BY a.ZNOTE ASC, a.ZCREATIONDATE ASC, a.Z_PK ASC;
        """
        if sqlite3_prepare_v2(database, attachQuery, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let notePK = sqlite3_column_int64(statement, 0)
                let aIdent = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let aFilename = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let mIdent = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                let mFilename = sqlite3_column_text(statement, 4).map { String(cString: $0) }
                let attachmentPK = sqlite3_column_int64(statement, 5)

                let ident = mIdent ?? aIdent

                if let fileURL = findMediaFile(baseFolder: baseFolder, identifier: ident, filename: mFilename ?? aFilename) {
                    if noteAttachments[notePK] == nil {
                        noteAttachments[notePK] = []
                    }
                    let fallbackKey = "attachment-pk:\(attachmentPK)"
                    let source = SnapshotAttachmentSource(
                        sourceKey: ident ?? aIdent ?? fallbackKey,
                        identifier: aIdent,
                        mediaIdentifier: mIdent,
                        filename: mFilename ?? aFilename ?? fileURL.lastPathComponent,
                        fileURL: fileURL
                    )
                    noteAttachments[notePK]?.append(source)
                }
            }
            sqlite3_finalize(statement)
        }

        // 3. Read notes (Z_ENT = 12)
        var candidates: [SnapshotNoteCandidate] = []
        let noteQuery = """
        SELECT n.Z_PK, n.ZTITLE1, n.ZSNIPPET, n.ZFOLDER, n.ZMODIFICATIONDATE1, n.ZIDENTIFIER, d.ZDATA
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICNOTEDATA d ON n.ZNOTEDATA = d.Z_PK
        WHERE n.Z_ENT = 12 AND (n.ZMARKEDFORDELETION IS NULL OR n.ZMARKEDFORDELETION = 0);
        """

        if sqlite3_prepare_v2(database, noteQuery, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let pk = sqlite3_column_int64(statement, 0)
                let explicitTitle = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let snippet = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let folderPK = sqlite3_column_int64(statement, 3)
                let modTimestamp = sqlite3_column_double(statement, 4)
                let identifier = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? UUID().uuidString

                // Read binary protobuf data
                var extractedText: String?
                var extractedBlocks: [SnapshotContentBlock]?
                if let blobPointer = sqlite3_column_blob(statement, 6) {
                    let blobBytes = sqlite3_column_bytes(statement, 6)
                    let data = Data(bytes: blobPointer, count: Int(blobBytes))
                    if let decompressed = decompressGzip(data) {
                        extractedText = extractProtobufText(decompressed)
                        extractedBlocks = extractStructuredContent(from: decompressed, attachments: noteAttachments[pk] ?? [])
                    }
                }

                let body = extractedText ?? snippet ?? ""
                let title: String
                if let explicitTitle, !explicitTitle.isEmpty {
                    title = explicitTitle
                } else {
                    let firstLine = body.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                    title = firstLine ?? "Ohne Titel"
                }

                let attachments = noteAttachments[pk] ?? []
                guard !body.isEmpty || !attachments.isEmpty else { continue }

                let folderName = folders[folderPK] ?? "Notizen"
                let modifiedDate = modTimestamp > 0
                    ? Date(timeIntervalSinceReferenceDate: modTimestamp)
                    : Date()

                let contentBlocks = normalizeBlocks(
                    extractedBlocks ?? ([.text(body)] + attachments.map { .attachment(sourceKey: $0.sourceKey) })
                )
                let bodyText = bodyFromBlocks(contentBlocks)

                candidates.append(SnapshotNoteCandidate(
                    title: title,
                    body: bodyText.isEmpty ? body : bodyText,
                    folder: folderName,
                    attachmentSources: attachments,
                    contentBlocks: contentBlocks,
                    modifiedAt: modifiedDate,
                    sourceID: "applenotes:\(identifier)"
                ))
            }
            sqlite3_finalize(statement)
        }

        return candidates
    }

    private static func extractStructuredContent(from data: Data, attachments: [SnapshotAttachmentSource]) -> [SnapshotContentBlock]? {
        let plainText = extractProtobufText(data)
        if let attributed = extractAttributedText(from: data) {
            let attributedBlocks = contentBlocks(from: attributed, attachments: attachments)
            if !attributedBlocks.isEmpty {
                return normalizeBlocks(attributedBlocks)
            }
            let markdown = markdownString(from: attributed)
            let chosen = preferredStructuredText(plainText: plainText, attributedText: markdown)
            return buildContentBlocks(from: chosen, attachments: attachments)
        }
        if let text = plainText {
            return buildContentBlocks(from: text, attachments: attachments)
        }
        return nil
    }

    private static func preferredStructuredText(plainText: String?, attributedText: String) -> String {
        let placeholder = "\u{FFFC}"
        let plain = plainText ?? ""
        let attributed = attributedText

        if attributed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plain
        }
        if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return attributed
        }

        let plainHasPlaceholder = plain.contains(placeholder)
        let attributedHasPlaceholder = attributed.contains(placeholder)

        if attributedHasPlaceholder && !plainHasPlaceholder {
            return attributed
        }
        if plainHasPlaceholder && !attributedHasPlaceholder {
            return plain
        }

        let plainBullets = bulletCount(in: plain)
        let attributedBullets = bulletCount(in: attributed)
        if plainBullets > attributedBullets {
            return plain
        }

        // If attributed extraction is much shorter, keep full plain text to avoid losing headings/sections.
        if attributed.count * 5 < plain.count * 4 {
            return plain
        }

        return attributed
    }

    private static func bulletCount(in text: String) -> Int {
        let bulletChars: Set<Character> = ["•", "◦", "▪", "▫", "●", "-", "*"]
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) { count, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { return }
            if bulletChars.contains(first) {
                count += 1
            }
        }
    }

    private static func extractAttributedText(from data: Data) -> NSAttributedString? {
        let fields = protobufFields(in: data)
        var bestMatch: NSAttributedString?
        var bestLength = 0

        for field in fields {
            guard case .lengthDelimited(let payload) = field.value else { continue }
            if let attributed = decodeAttributedStringArchive(payload), attributed.string.count > bestLength {
                bestLength = attributed.string.count
                bestMatch = attributed
            }
            if let nested = extractAttributedText(from: payload), nested.string.count > bestLength {
                bestLength = nested.string.count
                bestMatch = nested
            }
        }

        return bestMatch
    }

    private static func decodeAttributedStringArchive(_ data: Data) -> NSAttributedString? {
        guard data.starts(with: Data("bplist00".utf8)) else { return nil }
        if let attributed = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? NSAttributedString {
            return attributed
        }
        if let mutable = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? NSMutableAttributedString {
            return NSAttributedString(attributedString: mutable)
        }
        return nil
    }

    private static func markdownString(from attributed: NSAttributedString) -> String {
        var pieces: [String] = []
        let fullRange = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            let raw = attributed.attributedSubstring(from: range).string
            if raw.isEmpty {
                return
            }

            if let linkValue = attributes[.link] {
                let href: String
                if let url = linkValue as? URL {
                    href = url.absoluteString
                } else {
                    href = String(describing: linkValue)
                }
                pieces.append("[\(raw)](\(href))")
                return
            }

            var text = raw
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isMonospace = traits.contains(.monoSpace)
            let isBold = traits.contains(.bold)
            let isItalic = traits.contains(.italic)
            let hasUnderline = (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 > 0
            let hasStrikethrough = (attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 > 0

            if isMonospace {
                text = "`\(text)`"
            } else {
                if isBold && isItalic {
                    text = "***\(text)***"
                } else if isBold {
                    text = "**\(text)**"
                } else if isItalic {
                    text = "_\(text)_"
                }
            }

            if hasUnderline {
                text = "<u>\(text)</u>"
            }
            if hasStrikethrough {
                text = "~~\(text)~~"
            }

            pieces.append(text)
        }

        return pieces.joined()
    }

    private static func contentBlocks(from attributed: NSAttributedString, attachments: [SnapshotAttachmentSource]) -> [SnapshotContentBlock] {
        var blocks: [SnapshotContentBlock] = []
        var usedKeys = Set<String>()
        var fallbackIndex = 0
        var payloadDigests: [String: String] = [:]
        let fullRange = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let sourceKey = resolveAttachmentSourceKey(
                    attachment: attachment,
                    attachments: attachments,
                    usedKeys: &usedKeys,
                    fallbackIndex: &fallbackIndex,
                    payloadDigests: &payloadDigests
                ) {
                    blocks.append(.attachment(sourceKey: sourceKey))
                }
                return
            }

            let raw = attributed.attributedSubstring(from: range).string
            if raw.isEmpty {
                return
            }

            let segment = formattedSegment(raw: raw, attributes: attributes)
            if !segment.isEmpty {
                blocks.append(.text(segment))
            }
        }

        while fallbackIndex < attachments.count {
            let source = attachments[fallbackIndex]
            if !usedKeys.contains(source.sourceKey) {
                usedKeys.insert(source.sourceKey)
                blocks.append(.attachment(sourceKey: source.sourceKey))
            }
            fallbackIndex += 1
        }

        return blocks
    }

    private static func resolveAttachmentSourceKey(
        attachment: NSTextAttachment,
        attachments: [SnapshotAttachmentSource],
        usedKeys: inout Set<String>,
        fallbackIndex: inout Int,
        payloadDigests: inout [String: String]
    ) -> String? {
        let preferredName = normalizedFilename(attachment.fileWrapper?.preferredFilename)
        if let preferredName {
            let ranked = attachments
                .filter { !usedKeys.contains($0.sourceKey) }
                .map { source -> (SnapshotAttachmentSource, Int) in
                    let sourceName = normalizedFilename(source.filename) ?? ""
                    let score: Int
                    if sourceName == preferredName {
                        score = 100
                    } else if sourceName.replacingOccurrences(of: ".", with: "") == preferredName.replacingOccurrences(of: ".", with: "") {
                        score = 90
                    } else if sourceName.contains(preferredName) || preferredName.contains(sourceName) {
                        score = 70
                    } else {
                        score = 0
                    }
                    return (source, score)
                }
                .sorted { lhs, rhs in lhs.1 > rhs.1 }
            if let best = ranked.first, best.1 > 0 {
                usedKeys.insert(best.0.sourceKey)
                return best.0.sourceKey
            }
        }

        if let digest = attachmentPayloadDigest(attachment) {
            for source in attachments where !usedKeys.contains(source.sourceKey) {
                let sourceDigest: String
                if let cached = payloadDigests[source.sourceKey] {
                    sourceDigest = cached
                } else {
                    let computed = filePayloadDigest(source.fileURL)
                    payloadDigests[source.sourceKey] = computed
                    sourceDigest = computed
                }
                if !sourceDigest.isEmpty && sourceDigest == digest {
                    usedKeys.insert(source.sourceKey)
                    return source.sourceKey
                }
            }
        }

        if let preferredImageSize = attachmentImageSize(attachment) {
            let candidates = attachments.filter { !usedKeys.contains($0.sourceKey) }
            let ranked = candidates.compactMap { source -> (SnapshotAttachmentSource, CGFloat)? in
                guard let sourceSize = imageSize(for: source.fileURL) else { return nil }
                return (source, imageSizeDistance(preferred: preferredImageSize, candidate: sourceSize))
            }
            .sorted { $0.1 < $1.1 }
            if let best = ranked.first {
                usedKeys.insert(best.0.sourceKey)
                return best.0.sourceKey
            }
        }

        while fallbackIndex < attachments.count {
            let source = attachments[fallbackIndex]
            fallbackIndex += 1
            if !usedKeys.contains(source.sourceKey) {
                usedKeys.insert(source.sourceKey)
                return source.sourceKey
            }
        }
        return nil
    }

    private static func normalizedFilename(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func attachmentPayloadDigest(_ attachment: NSTextAttachment) -> String? {
        if let data = attachment.fileWrapper?.regularFileContents, !data.isEmpty {
            return digestHex(data)
        }
        if let image = attachment.image,
           let tiff = image.tiffRepresentation,
           !tiff.isEmpty {
            return digestHex(tiff)
        }
        return nil
    }

    private static func filePayloadDigest(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return ""
        }
        return digestHex(data)
    }

    private static func digestHex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func attachmentImageSize(_ attachment: NSTextAttachment) -> CGSize? {
        if let image = attachment.image {
            return image.size
        }
        if let data = attachment.fileWrapper?.regularFileContents,
           let image = NSImage(data: data) {
            return image.size
        }
        return nil
    }

    private static func imageSize(for url: URL) -> CGSize? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return image.size
    }

    private static func imageSizeDistance(preferred: CGSize, candidate: CGSize) -> CGFloat {
        let preferredArea = max(preferred.width * preferred.height, 1)
        let candidateArea = max(candidate.width * candidate.height, 1)
        let areaDelta = abs(log(preferredArea) - log(candidateArea))

        let preferredRatio = max(preferred.width, 1) / max(preferred.height, 1)
        let candidateRatio = max(candidate.width, 1) / max(candidate.height, 1)
        let ratioDelta = abs(preferredRatio - candidateRatio)

        return areaDelta + (ratioDelta * 3)
    }

    private static func formattedSegment(raw: String, attributes: [NSAttributedString.Key: Any]) -> String {
        var text = raw
        if text.contains("\u{FFFC}") {
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        }
        guard !text.isEmpty else { return "" }

        if let linkValue = attributes[.link] {
            let href: String
            if let url = linkValue as? URL {
                href = url.absoluteString
            } else {
                href = String(describing: linkValue)
            }
            text = "[\(text)](\(href))"
        } else {
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isMonospace = traits.contains(.monoSpace)
            let isBold = traits.contains(.bold)
            let isItalic = traits.contains(.italic)
            let hasUnderline = (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 > 0
            let hasStrikethrough = (attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 > 0

            if isMonospace {
                text = "`\(text)`"
            } else if isBold && isItalic {
                text = "***\(text)***"
            } else if isBold {
                text = "**\(text)**"
            } else if isItalic {
                text = "_\(text)_"
            }

            if hasUnderline {
                text = "<u>\(text)</u>"
            }
            if hasStrikethrough {
                text = "~~\(text)~~"
            }
        }

        if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle,
           (!paragraphStyle.textLists.isEmpty || paragraphStyle.headIndent >= 12) {
            text = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    let value = String(line)
                    if value.trimmingCharacters(in: .whitespaces).isEmpty {
                        return value
                    }
                    if value.trimmingCharacters(in: .whitespaces).hasPrefix("•") ||
                        value.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                        return value
                    }
                    return "• \(value)"
                }
                .joined(separator: "\n")
        }

        return text
    }

    private static func buildContentBlocks(from text: String, attachments: [SnapshotAttachmentSource]) -> [SnapshotContentBlock] {
        let placeholder = "\u{FFFC}"
        var blocks: [SnapshotContentBlock] = []
        var attachmentIndex = 0
        let parts = text.components(separatedBy: placeholder)

        for index in parts.indices {
            let part = parts[index]
            if !part.isEmpty {
                blocks.append(.text(part))
            }
            if index < parts.count - 1, attachmentIndex < attachments.count {
                blocks.append(.attachment(sourceKey: attachments[attachmentIndex].sourceKey))
                attachmentIndex += 1
            }
        }

        while attachmentIndex < attachments.count {
            blocks.append(.attachment(sourceKey: attachments[attachmentIndex].sourceKey))
            attachmentIndex += 1
        }

        if blocks.isEmpty, !text.isEmpty {
            blocks = [.text(text)]
        }

        return blocks
    }

    private static func normalizeBlocks(_ blocks: [SnapshotContentBlock]) -> [SnapshotContentBlock] {
        let compacted = blocks.compactMap { (block: SnapshotContentBlock) -> SnapshotContentBlock? in
            switch block {
            case .text(let value):
                let compact = value.replacingOccurrences(of: "\u{FFFC}", with: "")
                return compact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(value)
            case .attachment(let sourceKey):
                return .attachment(sourceKey: sourceKey)
            }
        }
        let perBlockRestored = compacted.map { (block: SnapshotContentBlock) -> SnapshotContentBlock in
            guard case .text(let value) = block else { return block }
            return .text(restoredInhaltsverzeichnisBullets(in: value))
        }
        return restoredInhaltsverzeichnisBulletsAcrossBlocks(perBlockRestored)
    }

    private static func restoredInhaltsverzeichnisBulletsAcrossBlocks(_ blocks: [SnapshotContentBlock]) -> [SnapshotContentBlock] {
        guard let headingIndex = blocks.firstIndex(where: { block in
            guard case .text(let value) = block else { return false }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveContains("inhaltsverzeichnis")
        }) else {
            return blocks
        }

        var updated = blocks
        var index = headingIndex + 1
        var changed = 0

        while index < updated.count {
            switch updated[index] {
            case .attachment:
                return changed >= 2 ? updated : blocks
            case .text(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return changed >= 2 ? updated : blocks
                }

                let lines = value.components(separatedBy: "\n")
                let shortBlock = lines.count <= 3 && trimmed.count <= 90
                if !shortBlock {
                    return changed >= 2 ? updated : blocks
                }

                let rebuilt = lines.map { line -> String in
                    let base = line.trimmingCharacters(in: .whitespaces)
                    if base.isEmpty { return line }
                    if base.hasPrefix("•") || base.hasPrefix("-") || base.hasPrefix("*") {
                        return line
                    }
                    if let first = base.first, first.isNumber { return line }
                    let leadingCount = line.prefix { $0 == " " || $0 == "\t" }.count
                    let leading = String(line.prefix(leadingCount))
                    let content = String(line.dropFirst(leadingCount))
                    return "\(leading)• \(content)"
                }
                let merged = rebuilt.joined(separator: "\n")
                if merged != value {
                    updated[index] = .text(merged)
                    changed += 1
                }
            }
            index += 1
        }

        return changed >= 2 ? updated : blocks
    }

    private static func restoredInhaltsverzeichnisBullets(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let headingIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveContains("inhaltsverzeichnis")
        }) else {
            return text
        }

        var endIndex = headingIndex + 1
        while endIndex < lines.count {
            let trimmed = lines[endIndex].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                break
            }
            endIndex += 1
        }

        guard endIndex - headingIndex - 1 >= 3 else {
            return text
        }

        var updated = lines
        for index in (headingIndex + 1)..<endIndex {
            let original = updated[index]
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") { continue }
            if let first = trimmed.first, first.isNumber { continue }
            if trimmed.count > 90 { continue }

            let leadingWhitespaceCount = original.prefix { $0 == " " || $0 == "\t" }.count
            let leading = String(original.prefix(leadingWhitespaceCount))
            let content = String(original.dropFirst(leadingWhitespaceCount))
            updated[index] = "\(leading)• \(content)"
        }

        return updated.joined(separator: "\n")
    }

    private static func bodyFromBlocks(_ blocks: [SnapshotContentBlock]) -> String {
        blocks.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func findMediaFile(baseFolder: URL, identifier: String?, filename: String?) -> URL? {
        let fileManager = FileManager.default

        // Direct accounts media check
        if let identifier {
            let accountsURL = baseFolder.appendingPathComponent("Accounts", isDirectory: true)
            if let accountDirs = try? fileManager.contentsOfDirectory(at: accountsURL, includingPropertiesForKeys: nil) {
                for accountDir in accountDirs {
                    let mediaDir = accountDir.appendingPathComponent("Media/\(identifier)", isDirectory: true)
                    if let filename,
                       let genDirs = try? fileManager.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) {
                        for genDir in genDirs {
                            let candidate = genDir.appendingPathComponent(filename)
                            if fileManager.fileExists(atPath: candidate.path) {
                                return candidate
                            }
                        }
                    }
                    if let filename {
                        let directCandidate = mediaDir.appendingPathComponent(filename)
                        if fileManager.fileExists(atPath: directCandidate.path) {
                            return directCandidate
                        }
                    }
                    if let fallback = firstRegularFile(in: mediaDir) {
                        return fallback
                    }
                }
            }
        }

        // Deep search in baseFolder if direct search misses
        if let enumerator = fileManager.enumerator(at: baseFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let filename {
                    if fileURL.lastPathComponent == filename {
                        return fileURL
                    }
                } else if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    return fileURL
                }
            }
        }

        return nil
    }

    private static func firstRegularFile(in folder: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return fileURL
            }
        }
        return nil
    }

    // MARK: - Protobuf Note Body Extraction (Field 2 -> Field 3 -> Field 2)

    static func extractProtobufText(_ data: Data) -> String? {
        guard let f2 = getProtobufField(data, targetField: 2) else { return nil }
        guard let f3 = getProtobufField(f2, targetField: 3) else { return nil }
        guard let f2_inner = getProtobufField(f3, targetField: 2) else { return nil }
        return String(data: f2_inner, encoding: .utf8)
    }

    static func protobufFields(in data: Data) -> [ProtobufField] {
        var fields: [ProtobufField] = []
        var position = 0

        while position < data.count {
            guard let (tag, afterTag) = readVarint(data, from: position) else { break }
            position = afterTag

            let fieldNumber = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let (value, afterValue) = readVarint(data, from: position) else { return fields }
                fields.append(ProtobufField(number: fieldNumber, value: .varint(value)))
                position = afterValue
            case 1:
                let end = position + 8
                guard end <= data.count else { return fields }
                fields.append(ProtobufField(number: fieldNumber, value: .fixed64(data.subdata(in: position..<end))))
                position = end
            case 2:
                guard let (length, afterLength) = readVarint(data, from: position) else { return fields }
                let end = afterLength + Int(length)
                guard end <= data.count else { return fields }
                fields.append(ProtobufField(number: fieldNumber, value: .lengthDelimited(data.subdata(in: afterLength..<end))))
                position = end
            case 5:
                let end = position + 4
                guard end <= data.count else { return fields }
                fields.append(ProtobufField(number: fieldNumber, value: .fixed32(data.subdata(in: position..<end))))
                position = end
            default:
                return fields
            }
        }

        return fields
    }

    private static func getProtobufField(_ data: Data, targetField: Int) -> Data? {
        var pos = 0
        while pos < data.count {
            guard let (tag, newPos) = readVarint(data, from: pos) else { break }
            pos = newPos
            let wire = tag & 7
            let fieldNum = tag >> 3

            if wire == 2 { // length delimited
                guard let (length, afterLenPos) = readVarint(data, from: pos) else { break }
                let start = afterLenPos
                let end = start + Int(length)
                guard end <= data.count else { break }
                pos = end
                if fieldNum == targetField {
                    return data.subdata(in: start..<end)
                }
            } else if wire == 0 { // varint
                guard let (_, afterValPos) = readVarint(data, from: pos) else { break }
                pos = afterValPos
            } else if wire == 5 { // 32-bit
                pos += 4
            } else if wire == 1 { // 64-bit
                pos += 8
            } else {
                break
            }
        }
        return nil
    }

    private static func readVarint(_ data: Data, from startPos: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var pos = startPos
        while pos < data.count {
            let byte = data[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return (result, pos)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    // MARK: - Gzip Decompression

    static func decompressGzip(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var decompressed = Data()
        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(bufferSize)
                let status = inflate(&stream, Z_NO_FLUSH)
                if status != Z_OK && status != Z_STREAM_END { break }
                let bytesDecompressed = bufferSize - Int(stream.avail_out)
                if bytesDecompressed > 0 {
                    decompressed.append(buffer, count: bytesDecompressed)
                }
                if status == Z_STREAM_END { break }
            } while stream.avail_in > 0
        }
        return decompressed.isEmpty ? nil : decompressed
    }

    // MARK: - Generic SQLite Inspection & Fallback

    private static func inspectDatabase(_ url: URL) -> SQLiteInspection? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        let query = "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return SQLiteInspection(file: url.lastPathComponent, tables: [])
        }
        defer { sqlite3_finalize(statement) }

        var tables: [SQLiteTable] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: namePointer)
            let sql = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            tables.append(SQLiteTable(
                id: name,
                name: name,
                sql: sql,
                columns: columns(in: database, table: name),
                rowCount: rowCount(in: database, table: name),
                role: .unknown
            ))
        }
        return SQLiteInspection(file: url.lastPathComponent, tables: tables.map(classify))
    }

    private static func readGenericNoteCandidates(from url: URL) -> [SnapshotNoteCandidate] {
        guard let inspection = inspectDatabase(url) else { return [] }
        return inspection.tables
            .filter { $0.role == .note && $0.rowCount > 0 }
            .flatMap { readNotes(from: url, table: $0) }
    }

    private static func readNotes(from url: URL, table: SQLiteTable) -> [SnapshotNoteCandidate] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }

        let titleColumn = firstColumn(in: table.columns, matching: ["title", "name"])
        let bodyColumn = firstColumn(in: table.columns, matching: ["notetext", "body", "content", "text", "snippet"])
        guard let bodyColumn else { return [] }
        let query = "SELECT \(quote(titleColumn ?? bodyColumn)), \(quote(bodyColumn)) FROM \(quote(table.name))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var candidates: [SnapshotNoteCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let title = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "Neue Notiz"
            let body = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard !body.isEmpty else { continue }
            candidates.append(SnapshotNoteCandidate(
                title: title.isEmpty ? "Ohne Titel" : title,
                body: body,
                folder: "Notizen",
                attachmentSources: [],
                contentBlocks: [.text(body)],
                modifiedAt: Date(),
                sourceID: "generic:\(title.hashValue):\(body.hashValue)"
            ))
        }
        return candidates
    }

    private static func firstColumn(in columns: [String], matching names: [String]) -> String? {
        columns.first { column in
            names.contains { column.lowercased() == $0 }
        }
    }

    private static func classify(_ table: SQLiteTable) -> SQLiteTable {
        let name = table.name.lowercased()
        let columns = Set(table.columns.map { $0.lowercased() })
        let role: SQLiteTableRole
        if name.contains("attachment") || columns.contains("attachment") || columns.contains("filename") {
            role = .attachment
        } else if name.contains("folder") || columns.contains("folder") || columns.contains("folderid") {
            role = .folder
        } else if name.contains("note") || columns.contains("notetext") || columns.contains("title") || name.contains("ziccloudsyncingobject") {
            role = .note
        } else {
            role = .unknown
        }
        return SQLiteTable(
            id: table.id,
            name: table.name,
            sql: table.sql,
            columns: table.columns,
            rowCount: table.rowCount,
            role: role
        )
    }

    private static func columns(in database: OpaquePointer?, table: String) -> [String] {
        var statement: OpaquePointer?
        let query = "PRAGMA table_info(\(quote(table)))"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                names.append(String(cString: name))
            }
        }
        return names
    }

    private static func rowCount(in database: OpaquePointer?, table: String) -> Int {
        var statement: OpaquePointer?
        let query = "SELECT COUNT(*) FROM \(quote(table))"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
