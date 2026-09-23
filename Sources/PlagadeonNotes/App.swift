import SwiftUI
import UniformTypeIdentifiers
import AVKit
import AppKit
import PDFKit

private struct NoteIdentity: Hashable {
    let sourceID: String?
    let title: String
    let body: String
    let contentSignature: String
}

enum NoteExporter {
    static func markdown(_ note: Note) -> String {
        var output = "# \(note.title)\n\n"
        output += renderMarkdownBody(note)
        return output
    }

    static func html(_ note: Note) -> String {
        let title = escape(note.title)
        let body = renderHTMLBody(note)
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(title)</title></head><body><h1>\(title)</h1>\(body)</body></html>"
    }

    static func pdfData(_ note: Note) -> Data? {
        let text = "\(note.title)\n\n\(note.body)\n\nAnhänge:\n" + note.attachments.map(\.name).joined(separator: "\n")
        let document = PDFDocument()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, start) in stride(from: 0, to: max(lines.count, 1), by: 45).enumerated() {
            let pageText = lines[start..<min(start + 45, lines.count)].joined(separator: "\n")
            let image = NSImage(size: NSSize(width: 612, height: 792))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            NSAttributedString(string: pageText, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                .draw(in: NSRect(x: 36, y: 36, width: 540, height: 720))
            image.unlockFocus()
            guard let page = PDFPage(image: image) else { return nil }
            document.insert(page, at: index)
        }
        return document.dataRepresentation()
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func renderMarkdownBody(_ note: Note) -> String {
        let attachmentsByID = Dictionary(uniqueKeysWithValues: note.attachments.map { ($0.id, $0) })
        let blocks = note.contentBlocks.isEmpty ? [.text(note.body)] : note.contentBlocks
        var lines: [String] = []

        for block in blocks {
            switch block {
            case .text(let text):
                lines.append(text)
            case .attachment(let id):
                guard let attachment = attachmentsByID[id] else { continue }
                let path = "attachments/\(attachment.path)"
                let ext = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "heic", "gif", "tiff", "webp"].contains(ext) {
                    lines.append("![\(attachment.name)](\(path))")
                } else {
                    lines.append("[\(attachment.name)](\(path))")
                }
            }
        }

        return lines.joined(separator: "\n\n") + "\n"
    }

    private static func renderHTMLBody(_ note: Note) -> String {
        let attachmentsByID = Dictionary(uniqueKeysWithValues: note.attachments.map { ($0.id, $0) })
        let blocks = note.contentBlocks.isEmpty ? [.text(note.body)] : note.contentBlocks
        var sections: [String] = []

        for block in blocks {
            switch block {
            case .text(let text):
                let htmlText = escape(text).replacingOccurrences(of: "\n", with: "<br>\n")
                sections.append("<p>\(htmlText)</p>")
            case .attachment(let id):
                guard let attachment = attachmentsByID[id] else { continue }
                let path = "attachments/\(attachment.path)"
                let ext = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "heic", "gif", "tiff", "webp"].contains(ext) {
                    sections.append("<p><img src=\"\(path)\" alt=\"\(escape(attachment.name))\" style=\"max-width:100%;height:auto;\"></p>")
                } else {
                    sections.append("<p><a href=\"\(path)\">\(escape(attachment.name))</a></p>")
                }
            }
        }

        return sections.joined(separator: "\n")
    }
}

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "Neue Notiz"
    var body = ""
    var attachments: [Attachment] = []
    var folder = "Notizen"
    var tags: [String] = []
    var contentBlocks: [NoteContentBlock] = []
    var sourceID: String?
    var modifiedAt = Date()

    enum CodingKeys: String, CodingKey {
        case id, title, body, attachments, folder, tags, contentBlocks, sourceID, modifiedAt
    }

    init(
        id: UUID = UUID(),
        title: String = "Neue Notiz",
        body: String = "",
        attachments: [Attachment] = [],
        folder: String = "Notizen",
        tags: [String] = [],
        contentBlocks: [NoteContentBlock] = [],
        sourceID: String? = nil,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.attachments = attachments
        self.folder = folder
        self.tags = tags
        self.contentBlocks = contentBlocks
        self.sourceID = sourceID
        self.modifiedAt = modifiedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Neue Notiz"
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        folder = try values.decodeIfPresent(String.self, forKey: .folder) ?? "Notizen"
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        contentBlocks = try values.decodeIfPresent([NoteContentBlock].self, forKey: .contentBlocks) ?? []
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }
}

enum NoteContentBlock: Codable, Equatable, Identifiable {
    case text(String)
    case attachment(UUID)

    var id: String {
        switch self {
        case .text(let value):
            return "text:\(value.hashValue)"
        case .attachment(let attachmentID):
            return "attachment:\(attachmentID.uuidString)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    private enum BlockType: String, Codable {
        case text
        case attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BlockType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .attachment:
            self = .attachment(try container.decode(UUID.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(BlockType.text, forKey: .type)
            try container.encode(value, forKey: .value)
        case .attachment(let attachmentID):
            try container.encode(BlockType.attachment, forKey: .type)
            try container.encode(attachmentID, forKey: .value)
        }
    }
}

struct Attachment: Identifiable, Codable, Equatable {
    var id = UUID()
    let name: String
    let path: String
}

struct ImportSummary {
    let notes: Int
    let attachments: Int
}

struct SnapshotSummary {
    let folder: URL
    let files: Int
    let databases: Int
    let media: Int
    let tables: Int
    let candidates: Int
}

struct BackupRestoreResult {
    let imported: Int
    let error: String?
}

@MainActor
final class NoteStore: ObservableObject {
    @Published var notes: [Note] = [] {
        didSet { save() }
    }

    private let fileURL: URL
    private let attachmentsURL: URL
    private let snapshotsURL: URL

    init(baseDirectory: URL? = nil) {
        let directory: URL
        if let baseDirectory {
            directory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = appSupport.appendingPathComponent("PlagadeonNotes", isDirectory: true)
        }
        fileURL = directory.appendingPathComponent("notes.json")
        attachmentsURL = directory.appendingPathComponent("Attachments", isDirectory: true)
        snapshotsURL = directory.appendingPathComponent("Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        load()
        if notes.isEmpty { notes = [Note()] }
    }

    func addNote(in folder: String = "Notizen") {
        notes.insert(Note(folder: folder), at: 0)
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if notes.isEmpty { notes = [Note()] }
    }

    func deleteAllNotes() {
        notes = [Note()]
        try? FileManager.default.removeItem(at: attachmentsURL)
        try? FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
    }

    func deleteFolder(_ folder: String) {
        for index in notes.indices where notes[index].folder == folder {
            notes[index].folder = ""
            notes[index].modifiedAt = Date()
        }
        save()
    }

    func deleteTag(_ tag: String) {
        for index in notes.indices where notes[index].tags.contains(tag) {
            notes[index].tags.removeAll { $0 == tag }
            notes[index].modifiedAt = Date()
        }
        save()
    }

    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        save()
    }

    func importAttachment(from source: URL, into note: Note) {
        let destination = attachmentsURL.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        do {
            _ = source.startAccessingSecurityScopedResource()
            defer { source.stopAccessingSecurityScopedResource() }
            try FileManager.default.copyItem(at: source, to: destination)
            var updated = note
            updated.attachments.append(Attachment(name: source.lastPathComponent, path: destination.lastPathComponent))
            update(updated)
        } catch {
            print("Attachment import failed: \(error)")
        }
    }

    func url(for attachment: Attachment) -> URL {
        attachmentsURL.appendingPathComponent(attachment.path)
    }

    func importFolder(from source: URL) -> ImportSummary {
        let textExtensions = ["txt", "md", "markdown", "html", "htm"]
        let mediaExtensions = ["jpg", "jpeg", "png", "heic", "gif", "tiff", "pdf", "mov", "mp4", "m4v", "mp3", "m4a", "wav", "aiff"]
        var importedNotes = 0
        var importedAttachments = 0
        var newNotes: [Note] = []

        _ = source.startAccessingSecurityScopedResource()
        defer { source.stopAccessingSecurityScopedResource() }

        guard let files = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return ImportSummary(notes: 0, attachments: 0) }

        let urls = files.compactMap { $0 as? URL }
        for file in urls where textExtensions.contains(file.pathExtension.lowercased()) {
            guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var note = Note(title: file.deletingPathExtension().lastPathComponent, body: body)
            let siblings = urls.filter {
                $0.deletingLastPathComponent() == file.deletingLastPathComponent() &&
                mediaExtensions.contains($0.pathExtension.lowercased())
            }
            for attachment in siblings {
                if let storedAttachment = copyAttachment(attachment) {
                    note.attachments.append(storedAttachment)
                    importedAttachments += 1
                }
            }
            newNotes.append(note)
            importedNotes += 1
        }
        if !newNotes.isEmpty { notes = newNotes + notes }
        return ImportSummary(notes: importedNotes, attachments: importedAttachments)
    }

    private func copyAttachment(_ source: URL) -> Attachment? {
        let destination = attachmentsURL.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return Attachment(name: source.lastPathComponent, path: destination.lastPathComponent)
        } catch {
            return nil
        }
    }

    func snapshotAppleNotesFolder(from source: URL) -> SnapshotSummary? {
        let isAccessing = source.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { source.stopAccessingSecurityScopedResource() }
        }

        let destination = snapshotsURL.appendingPathComponent(
            "AppleNotes-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))",
            isDirectory: true
        )
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }

        let mediaExtensions = ["jpg", "jpeg", "png", "heic", "gif", "tiff", "pdf", "mov", "mp4", "m4v", "mp3", "m4a", "wav", "aiff"]
        let files = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []
        let regularFiles = files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let databases = regularFiles.filter { ["sqlite", "sqlite-shm", "sqlite-wal"].contains($0.pathExtension.lowercased()) }.count
        let media = regularFiles.filter { mediaExtensions.contains($0.pathExtension.lowercased()) }.count
        let inspections = AppleNotesSnapshotInspector.inspect(destination)
        let tables = inspections.reduce(0) { $0 + $1.tables.count }
        let candidates = inspections.flatMap(\.tables).filter { $0.role != .unknown }.count
        if let report = try? JSONEncoder().encode(inspections) {
            try? report.write(to: destination.appendingPathComponent("schema-report.json"), options: .atomic)
        }
        return SnapshotSummary(folder: destination, files: regularFiles.count, databases: databases, media: media, tables: tables, candidates: candidates)
    }

    func importSnapshot(from folder: URL) -> SnapshotImportReport {
        let candidates = AppleNotesSnapshotInspector.noteCandidates(in: folder)
        var existing = Set(notes.map {
            NoteIdentity(
                sourceID: $0.sourceID,
                title: $0.title,
                body: $0.body,
                contentSignature: contentSignature(for: $0.contentBlocks)
            )
        })
        var importedNotes: [Note] = []
        var updatedCount = 0
        var duplicateCount = 0
        var unresolvedAttachments = 0
        for candidate in candidates {
            let candidateIdentity = NoteIdentity(
                sourceID: candidate.sourceID,
                title: candidate.title,
                body: candidate.body,
                contentSignature: contentSignature(for: candidate.contentBlocks)
            )

            let sourceID = candidate.sourceID
            if let existingIndex = notes.firstIndex(where: { $0.sourceID == sourceID }) {
                let current = notes[existingIndex]
                let currentStructure = structureSignature(for: current.contentBlocks)
                let incomingAttachmentKeys = Set(candidate.attachmentSources.map(\.sourceKey))
                var incomingBlocks = candidate.contentBlocks.filter { block in
                    switch block {
                    case .text(let value):
                        return !value.isEmpty
                    case .attachment(let sourceKey):
                        return incomingAttachmentKeys.contains(sourceKey)
                    }
                }
                if incomingBlocks.isEmpty {
                    incomingBlocks = [.text(candidate.body)]
                }
                let incomingStructure = structureSignature(for: incomingBlocks)
                let incomingText = incomingBlocks.compactMap { block -> String? in
                    guard case .text(let value) = block else { return nil }
                    return value
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                let incomingBody = incomingText.isEmpty ? candidate.body : incomingText
                let currentAttachmentOrder = attachmentOrderSignature(for: current)
                let incomingAttachmentOrder = attachmentOrderSignature(for: candidate)
                let incomingAttachmentCount = Set(candidate.attachmentSources.map(\.sourceKey)).count
                let unchanged = current.title == candidate.title
                    && current.folder == candidate.folder
                    && currentStructure == incomingStructure
                    && current.body == incomingBody
                    && current.attachments.count == incomingAttachmentCount
                    && currentAttachmentOrder == incomingAttachmentOrder

                if unchanged {
                    duplicateCount += 1
                    continue
                }

                let materialized = materializeCandidate(candidate, unresolvedAttachments: &unresolvedAttachments)
                var replacement = materialized
                replacement.id = current.id
                replacement.tags = current.tags
                notes[existingIndex] = replacement
                updatedCount += 1
                existing.insert(candidateIdentity)
                continue
            }

            guard !existing.contains(candidateIdentity) else {
                duplicateCount += 1
                continue
            }

            importedNotes.append(materializeCandidate(candidate, unresolvedAttachments: &unresolvedAttachments))
            existing.insert(candidateIdentity)
        }
        if !importedNotes.isEmpty { notes = importedNotes + notes }
        return SnapshotImportReport(
            candidates: candidates.count,
            imported: importedNotes.count,
            updated: updatedCount,
            duplicates: duplicateCount,
            unresolvedAttachments: unresolvedAttachments
        )
    }

    private func materializeCandidate(_ candidate: SnapshotNoteCandidate, unresolvedAttachments: inout Int) -> Note {
        var attachmentBySourceKey: [String: Attachment] = [:]
        var noteAttachments: [Attachment] = []
        for sourceAttachment in candidate.attachmentSources {
            if attachmentBySourceKey[sourceAttachment.sourceKey] != nil {
                continue
            }
            if let stored = copyAttachment(sourceAttachment.fileURL) {
                noteAttachments.append(stored)
                attachmentBySourceKey[sourceAttachment.sourceKey] = stored
            } else {
                unresolvedAttachments += 1
            }
        }

        var contentBlocks: [NoteContentBlock] = []
        for block in candidate.contentBlocks {
            switch block {
            case .text(let value):
                if !value.isEmpty {
                    contentBlocks.append(.text(value))
                }
            case .attachment(let sourceKey):
                if let attachment = attachmentBySourceKey[sourceKey] {
                    contentBlocks.append(.attachment(attachment.id))
                } else {
                    unresolvedAttachments += 1
                }
            }
        }
        if contentBlocks.isEmpty {
            contentBlocks = [.text(candidate.body)] + noteAttachments.map { .attachment($0.id) }
        }

        return Note(
            title: candidate.title,
            body: joinedText(from: contentBlocks, fallback: candidate.body),
            attachments: noteAttachments,
            folder: candidate.folder,
            tags: [],
            contentBlocks: contentBlocks,
            sourceID: candidate.sourceID,
            modifiedAt: candidate.modifiedAt
        )
    }

    private func joinedText(from blocks: [NoteContentBlock], fallback: String) -> String {
        let text = blocks.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    private func contentSignature(for blocks: [NoteContentBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        return blocks.map { block in
            switch block {
            case .text(let value):
                return "t:\(value)"
            case .attachment(let id):
                return "a:\(id.uuidString)"
            }
        }
        .joined(separator: "|")
    }

    private func contentSignature(for blocks: [SnapshotContentBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        return blocks.map { block in
            switch block {
            case .text(let value):
                return "t:\(value)"
            case .attachment(let sourceKey):
                return "a:\(sourceKey)"
            }
        }
        .joined(separator: "|")
    }

    private func structureSignature(for blocks: [NoteContentBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        return blocks.map { block in
            switch block {
            case .text(let value):
                return "t:\(value)"
            case .attachment:
                return "a"
            }
        }
        .joined(separator: "|")
    }

    private func structureSignature(for blocks: [SnapshotContentBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        return blocks.map { block in
            switch block {
            case .text(let value):
                return "t:\(value)"
            case .attachment:
                return "a"
            }
        }
        .joined(separator: "|")
    }

    private func attachmentOrderSignature(for note: Note) -> String {
        let attachmentByID = Dictionary(uniqueKeysWithValues: note.attachments.map { ($0.id, $0.name) })
        return note.contentBlocks.compactMap { block -> String? in
            guard case .attachment(let id) = block else { return nil }
            return attachmentByID[id] ?? ""
        }
        .joined(separator: "|")
    }

    private func attachmentOrderSignature(for candidate: SnapshotNoteCandidate) -> String {
        let byKey = Dictionary(uniqueKeysWithValues: candidate.attachmentSources.map { ($0.sourceKey, $0.filename) })
        return candidate.contentBlocks.compactMap { block -> String? in
            guard case .attachment(let sourceKey) = block else { return nil }
            return byKey[sourceKey]
        }
        .joined(separator: "|")
    }

    func importAppleNotesFolder(from source: URL) -> (SnapshotSummary?, SnapshotImportReport?) {
        guard let summary = snapshotAppleNotesFolder(from: source) else { return (nil, nil) }
        return (summary, importSnapshot(from: summary.folder))
    }

    func exportMarkdown(_ note: Note) {
        saveText(NoteExporter.markdown(note), suggestedName: "\(safeName(note.title)).md", type: .plainText)
    }

    func exportHTML(_ note: Note) {
        saveText(NoteExporter.html(note), suggestedName: "\(safeName(note.title)).html", type: .html)
    }

    func exportPDF(_ note: Note) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeName(note.title)).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = NoteExporter.pdfData(note) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func exportBackup() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "plagadeon-notes-backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    func restoreBackup(from url: URL) -> BackupRestoreResult {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let restored = try? JSONDecoder().decode([Note].self, from: data) else {
            return BackupRestoreResult(imported: 0, error: "Das Backup konnte nicht gelesen werden.")
        }
        var existing = Set(notes.map {
            NoteIdentity(
                sourceID: $0.sourceID,
                title: $0.title,
                body: $0.body,
                contentSignature: contentSignature(for: $0.contentBlocks)
            )
        })
        var importedNotes: [Note] = []
        for note in restored {
            let identity = NoteIdentity(
                sourceID: note.sourceID,
                title: note.title,
                body: note.body,
                contentSignature: contentSignature(for: note.contentBlocks)
            )
            guard existing.insert(identity).inserted else { continue }
            importedNotes.append(note)
        }
        if !importedNotes.isEmpty { notes = importedNotes + notes }
        return BackupRestoreResult(imported: importedNotes.count, error: nil)
    }

    private func saveText(_ text: String, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = text.data(using: .utf8) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func safeName(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "notiz" : name.replacingOccurrences(of: "/", with: "-")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Note].self, from: data) else { return }
        notes = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

let appEggshellColor = Color(red: 250 / 255.0, green: 248 / 255.0, blue: 232 / 255.0)
let appSelectedRowColor = Color(red: 231 / 255.0, green: 224 / 255.0, blue: 198 / 255.0)

struct WindowAppearanceConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        window.backgroundColor = NSColor(
            calibratedRed: 250 / 255.0,
            green: 248 / 255.0,
            blue: 232 / 255.0,
            alpha: 1
        )
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
    }
}

struct PlagadeonLogo: View {
    private static let originalSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
      <rect width="256" height="256" rx="56" fill="#292824"/>
      <circle cx="128" cy="128" r="82" fill="#E7E0C6"/>
      <path d="M82 82v92M82 82h48c25 0 38 13 38 32s-13 32-38 32H82" fill="none" stroke="#292824" stroke-width="13" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M143 157v23M143 157l18 23v-23" fill="none" stroke="#F28C28" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
      <circle cx="190" cy="70" r="15" fill="#F28C28"/>
    </svg>
    """

    var body: some View {
        Group {
            if let image = NSImage(data: Data(Self.originalSVG.utf8)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: 36, height: 36)
    }
}

@main
struct PlagadeonNotesApp: App {
    var body: some Scene {
        WindowGroup("Plagadeon Notes") {
            ContentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(appEggshellColor)
        }
    }
}

enum CategoryFilter: Hashable {
    case all
    case folder(String)
    case tag(String)
}

private extension Notification.Name {
    static let restorePlagadeonDividerPositions = Notification.Name("PlagadeonNotes.restoreDividerPositions")
}

struct ContentView: View {
    @StateObject private var store = NoteStore()
    @State private var selectedFilter: CategoryFilter = .all
    @State private var selectedID: Note.ID?
    @State private var searchText = ""
    @State private var showingFolderImporter = false
    @State private var importMessage: String?
    @State private var snapshotMessage: String?
    @State private var showingBackupImporter = false
    @State private var backupMessage: String?
    @State private var notePendingDeletion: Note?
    @State private var folderPendingDeletion: String?
    @State private var tagPendingDeletion: String?
    @State private var showingSingleNote = false
    @State private var logoTapCount = 0
    @State private var lastLogoTap = Date.distantPast
    @State private var showingDeleteAllDialog = false

    private var currentCategoryTitle: String {
        switch selectedFilter {
        case .all:
            return "Alle Notizen"
        case .folder(let folder):
            return folder
        case .tag(let tag):
            return "#\(tag)"
        }
    }

    private var availableFolders: [String] {
        let folders = Set(store.notes.map(\.folder))
        return folders.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var availableTags: [String] {
        let tags = Set(store.notes.flatMap(\.tags))
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func countNotes(in folder: String) -> Int {
        store.notes.filter { $0.folder == folder }.count
    }

    private func countNotes(withTag tag: String) -> Int {
        store.notes.filter { $0.tags.contains(tag) }.count
    }

    private var filteredNotes: [Note] {
        let categoryNotes: [Note]
        switch selectedFilter {
        case .all:
            categoryNotes = store.notes
        case .folder(let folder):
            categoryNotes = store.notes.filter { $0.folder == folder }
        case .tag(let tag):
            categoryNotes = store.notes.filter { $0.tags.contains(tag) }
        }

        guard !searchText.isEmpty else { return categoryNotes }
        return categoryNotes.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.body.localizedCaseInsensitiveContains(searchText) ||
            $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var sidebarColumn: some View {
        List {
                Section("Übersicht") {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.full")
                        Text("Alle Notizen")
                        Spacer()
                        Text("\(store.notes.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedFilter = .all }
                    .foregroundStyle(.primary)
                    .listRowBackground(selectedFilter == .all ? appSelectedRowColor : appEggshellColor)
                }

                Section("Kategorien / Ordner") {
                    ForEach(availableFolders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                            Text(folder)
                            Spacer()
                            Text("\(countNotes(in: folder))")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedFilter = .folder(folder) }
                        .foregroundStyle(.primary)
                        .listRowBackground(selectedFilter == .folder(folder) ? appSelectedRowColor : appEggshellColor)
                        .contextMenu {
                            Button("Kategorie löschen", role: .destructive) {
                                folderPendingDeletion = folder
                            }
                        }
                    }
                }

                if !availableTags.isEmpty {
                    Section("Tags") {
                        ForEach(availableTags, id: \.self) { tag in
                            HStack(spacing: 8) {
                                Image(systemName: "tag")
                                Text(tag)
                                Spacer()
                                Text("\(countNotes(withTag: tag))")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedFilter = .tag(tag) }
                            .foregroundStyle(.primary)
                            .listRowBackground(selectedFilter == .tag(tag) ? appSelectedRowColor : appEggshellColor)
                            .contextMenu {
                                Button("Tag löschen", role: .destructive) {
                                    tagPendingDeletion = tag
                                }
                            }
                        }
                    }
                }
            }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appEggshellColor)
    }

    private var contentColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Suchen", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(appEggshellColor)

            List {
                ForEach(filteredNotes) { note in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title.isEmpty ? "Ohne Titel" : note.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(note.body.isEmpty ? "Keine Vorschau" : note.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedID = note.id
                    }
                    .onTapGesture(count: 2) {
                        selectedID = note.id
                        showingSingleNote = true
                    }
                    .foregroundStyle(.primary)
                    .listRowBackground(selectedID == note.id ? appSelectedRowColor : appEggshellColor)
                }
                .onDelete { offsets in
                    notePendingDeletion = offsets.first.flatMap { filteredNotes[$0] }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appEggshellColor)
            .toolbar {
                Button(action: {
                    let folderName: String
                    if case .folder(let f) = selectedFilter {
                        folderName = f
                    } else {
                        folderName = "Notizen"
                    }
                    store.addNote(in: folderName)
                    selectedID = store.notes.first?.id
                }) {
                    Label("Neue Notiz", systemImage: "square.and.pencil")
                }
                .help("Neue Notiz")
                Button(action: { showingFolderImporter = true }) {
                    Label("Exportordner importieren", systemImage: "folder.badge.plus")
                }
                .help("Exportordner importieren")
                Button(action: chooseAppleNotesFolder) {
                    Label("Apple-Notizen importieren", systemImage: "note.text.badge.plus")
                }
                .help("Apple-Notizen importieren")
                Button(action: { showingBackupImporter = true }) {
                    Label("Backup wiederherstellen", systemImage: "arrow.clockwise.icloud")
                }
                .help("Backup wiederherstellen")
                Button(action: { notePendingDeletion = selectedID.flatMap { id in store.notes.first { $0.id == id } } }) {
                    Label("Notiz löschen", systemImage: "trash")
                }
                .disabled(selectedID == nil)
                .help("Notiz löschen")
            }
        }
        .background(appEggshellColor)
    }

    private var detailColumn: some View {
        Group {
            if let selectedID,
               let note = store.notes.first(where: { $0.id == selectedID }) {
                NoteEditor(note: note, store: store)
                    .id(note.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Keine Notiz ausgewählt")
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(appEggshellColor)
            }
            }
    }

    private var mainLayout: some View {
        HSplitView {
            sidebarColumn
                .frame(minWidth: 180, idealWidth: 220)

            contentColumn
                .frame(minWidth: 240, idealWidth: 320)

            detailColumn
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .background(appEggshellColor)
        .toolbarBackground(appEggshellColor, for: .automatic)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: handleLogoTap) {
                    PlagadeonLogo()
                }
                .buttonStyle(.plain)
                    .help("Plagadeon Notes")
            }
        }
        .overlay(WindowAppearanceConfigurator().allowsHitTesting(false))
    }

    private var singleNoteLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    showingSingleNote = false
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("Zurück zur Übersicht")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(appEggshellColor)

            if let selectedID,
               let note = store.notes.first(where: { $0.id == selectedID }) {
                NoteEditor(note: note, store: store)
                    .id(note.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Keine Notiz ausgewählt")
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(appEggshellColor)
    }

    var body: some View {
        ZStack {
            mainLayout
                .opacity(showingSingleNote ? 0 : 1)
                .allowsHitTesting(!showingSingleNote)

            if showingSingleNote {
                singleNoteLayout
            }
        }
        .overlay(SplitDividerCursorMonitor().allowsHitTesting(false))
        .onAppear { selectedID = store.notes.first?.id }
        .onChange(of: selectedFilter) { _ in
            if let currentID = selectedID, !filteredNotes.contains(where: { $0.id == currentID }) {
                selectedID = filteredNotes.first?.id
            }
            NotificationCenter.default.post(name: .restorePlagadeonDividerPositions, object: nil)
        }
        .fileImporter(
            isPresented: $showingFolderImporter,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let folder) = result else { return }
            let summary = store.importFolder(from: folder)
            importMessage = "Import abgeschlossen: \(summary.notes) Notizen und \(summary.attachments) Anhänge."
        }
        .alert("Import", isPresented: importMessageBinding) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .alert("Apple-Notes-Snapshot", isPresented: snapshotMessageBinding) {
            Button("OK") { snapshotMessage = nil }
        } message: {
            Text(snapshotMessage ?? "")
        }
        .fileImporter(
            isPresented: $showingBackupImporter,
            allowedContentTypes: [.json]
        ) { result in
            guard case .success(let url) = result else { return }
            let restore = store.restoreBackup(from: url)
            backupMessage = restore.error ?? "Wiederhergestellt: \(restore.imported) neue Notizen."
        }
        .alert("Backup", isPresented: backupMessageBinding) {
            Button("OK") { backupMessage = nil }
        } message: {
            Text(backupMessage ?? "")
        }
        .confirmationDialog(
            "Notiz löschen?",
            isPresented: noteDeletionBinding,
            presenting: notePendingDeletion
        ) { note in
            Button("Löschen", role: .destructive) {
                store.delete(note)
                notePendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) { notePendingDeletion = nil }
        } message: { note in
            Text(note.title.isEmpty ? "Ohne Titel" : note.title)
        }
        .confirmationDialog(
            "Kategorie löschen?",
            isPresented: folderDeletionBinding,
            presenting: folderPendingDeletion
        ) { folder in
            Button("Kategorie löschen", role: .destructive) {
                store.deleteFolder(folder)
                if selectedFilter == .folder(folder) {
                    selectedFilter = .all
                }
                folderPendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) { folderPendingDeletion = nil }
        } message: { folder in
            Text("Die Notizen bleiben erhalten und werden auf Ohne Kategorie gesetzt: \(folder)")
        }
        .confirmationDialog(
            "Tag löschen?",
            isPresented: tagDeletionBinding,
            presenting: tagPendingDeletion
        ) { tag in
            Button("Tag löschen", role: .destructive) {
                store.deleteTag(tag)
                if selectedFilter == .tag(tag) {
                    selectedFilter = .all
                }
                tagPendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) { tagPendingDeletion = nil }
        } message: { tag in
            Text("Der Tag wird aus allen Notizen entfernt: #\(tag)")
        }
        .confirmationDialog(
            "Alle Notizen löschen?",
            isPresented: $showingDeleteAllDialog
        ) {
            Button("Ja", role: .destructive) {
                store.deleteAllNotes()
                selectedID = store.notes.first?.id
                selectedFilter = .all
                showingDeleteAllDialog = false
            }
            Button("Nein", role: .cancel) {
                showingDeleteAllDialog = false
            }
        } message: {
            Text("Alle lokalen Notizen und Anhänge werden gelöscht.")
        }
    }

    private func handleLogoTap() {
        let now = Date()
        logoTapCount = now.timeIntervalSince(lastLogoTap) <= 1.5 ? logoTapCount + 1 : 1
        lastLogoTap = now
        if logoTapCount == 5 {
            logoTapCount = 0
            showingDeleteAllDialog = true
        }
    }

    private var tagDeletionBinding: Binding<Bool> {
        Binding(
            get: { tagPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    tagPendingDeletion = nil
                }
            }
        )
    }

    private var folderDeletionBinding: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    folderPendingDeletion = nil
                }
            }
        )
    }

    private var noteDeletionBinding: Binding<Bool> {
        Binding(
            get: { notePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    notePendingDeletion = nil
                }
            }
        )
    }

    private var importMessageBinding: Binding<Bool> {
        Binding(
            get: { importMessage != nil },
            set: { isPresented in
                if !isPresented { importMessage = nil }
            }
        )
    }

    private var snapshotMessageBinding: Binding<Bool> {
        Binding(
            get: { snapshotMessage != nil },
            set: { isPresented in
                if !isPresented { snapshotMessage = nil }
            }
        )
    }

    private var backupMessageBinding: Binding<Bool> {
        Binding(
            get: { backupMessage != nil },
            set: { isPresented in
                if !isPresented { backupMessage = nil }
            }
        )
    }

    private func chooseAppleNotesFolder() {
        let defaultContainer = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes", isDirectory: true)

        let targetFolder: URL
        if FileManager.default.isReadableFile(atPath: defaultContainer.appendingPathComponent("NoteStore.sqlite").path) {
            targetFolder = defaultContainer
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = "Apple-Notes-Ordner auswählen"
            panel.message = "Wähle den lokalen Apple-Notes-Ordner aus. Die Quelle wird nur gelesen."
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = defaultContainer.deletingLastPathComponent()
            guard panel.runModal() == .OK, let folder = panel.url else {
                snapshotMessage = "Keine Apple-Notes-Quelle ausgewählt."
                return
            }
            targetFolder = folder
        }

        let result = store.importAppleNotesFolder(from: targetFolder)
        guard let summary = result.0, let importReport = result.1 else {
            snapshotMessage = "Der Apple-Notes-Ordner konnte nicht importiert werden. Bitte den Zugriff erlauben."
            return
        }
        snapshotMessage = "Import erfolgreich: \(importReport.imported) Notizen importiert, \(importReport.updated) bestehende Notizen aktualisiert, \(importReport.duplicates) Duplikate übersprungen, \(summary.media) Mediendateien gesichert."
        if importReport.unresolvedAttachments > 0 {
            snapshotMessage = (snapshotMessage ?? "") + " \(importReport.unresolvedAttachments) Anhänge konnten nicht vollständig aufgelöst werden."
        }
    }
}

struct ResizeDivider: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeDividerNSView {
        ResizeDividerNSView()
    }

    func updateNSView(_ nsView: ResizeDividerNSView, context: Context) {}
}

struct SplitDividerCursorMonitor: NSViewRepresentable {
    func makeNSView(context: Context) -> SplitDividerCursorView {
        SplitDividerCursorView()
    }

    func updateNSView(_ nsView: SplitDividerCursorView, context: Context) {}
}

final class SplitDividerCursorView: NSView {
    private var localMonitor: Any?
    private var resizeObservers: [NSObjectProtocol] = []
    private var cursorIsOnDivider = false
    private var dividerDragActive = false
    private var isRestoringDividerPositions = false
    private let dividerPositionsKey = "PlagadeonNotesDividerPositions"
    private let dividerDefaults = UserDefaults(suiteName: "de.plagadeon.notes")!

    private var dividerCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .columnResize
        }
        return .resizeLeftRight
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, localMonitor == nil {
            for splitView in splitViews(in: window?.contentView) {
                splitView.autosaveName = "PlagadeonNotesColumns"
            }
            observePrimarySplitViewWhenReady()
            DispatchQueue.main.async { [weak self] in
                self?.restoreSavedDividerPositions()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.restoreSavedDividerPositions()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.restoreSavedDividerPositions()
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                switch event.type {
                case .leftMouseDown:
                    self.updateCursor()
                    self.dividerDragActive = self.cursorIsOnDivider
                case .leftMouseDragged:
                    self.updateCursor()
                    if self.dividerDragActive {
                        self.saveDividerPositions()
                    }
                case .leftMouseUp:
                    if self.dividerDragActive {
                        self.saveDividerPositions()
                    }
                    self.dividerDragActive = false
                    self.updateCursor()
                default:
                    self.updateCursor()
                }
                return event
            }
        } else if window == nil {
            removeMonitors()
        }
    }

    override func removeFromSuperview() {
        removeMonitors()
        super.removeFromSuperview()
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        for resizeObserver in resizeObservers {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObservers.removeAll()
    }

    private func observePrimarySplitViewWhenReady() {
        let installObserver: () -> Void = { [weak self] in
            guard let self, self.resizeObservers.isEmpty,
                  let contentView = self.window?.contentView,
                  let splitView = self.primarySplitView(in: contentView) else { return }
            let resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: splitView,
                queue: .main
            ) { [weak self] _ in
                guard let self,
                      self.dividerDragActive,
                      !self.isRestoringDividerPositions else { return }
                self.saveDividerPositions()
            }
            let restoreObserver = NotificationCenter.default.addObserver(
                forName: .restorePlagadeonDividerPositions,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.restoreSavedDividerPositions()
                }
            }
            self.resizeObservers = [resizeObserver, restoreObserver]
        }
        installObserver()
        DispatchQueue.main.async(execute: installObserver)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: installObserver)
    }

    private func updateCursor() {
        guard let window else {
            if cursorIsOnDivider {
                cursorIsOnDivider = false
                NSCursor.arrow.set()
            }
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard window.contentView?.bounds.contains(windowPoint) == true else {
            if cursorIsOnDivider {
                cursorIsOnDivider = false
                NSCursor.arrow.set()
            }
            return
        }
        let dividerRects = splitViews(in: window.contentView).flatMap { splitView in
            (0..<max(splitView.subviews.count - 1, 0)).map { index in
                let dividerThickness = splitView.dividerThickness
                let previous = splitView.subviews[index].frame
                let rect: NSRect
                if splitView.isVertical {
                    rect = NSRect(
                        x: previous.maxX,
                        y: splitView.bounds.minY,
                        width: dividerThickness,
                        height: splitView.bounds.height
                    )
                } else {
                    rect = NSRect(
                        x: splitView.bounds.minX,
                        y: previous.maxY,
                        width: splitView.bounds.width,
                        height: dividerThickness
                    )
                }
                return splitView.convert(rect, to: window.contentView)
            }
        }
        let isOnDivider = dividerRects.contains {
            let expanded = $0.insetBy(dx: -7, dy: -2)
            return expanded.contains(windowPoint)
        }
        if isOnDivider {
            cursorIsOnDivider = true
            dividerCursor.set()
        } else if cursorIsOnDivider {
            cursorIsOnDivider = false
            NSCursor.arrow.set()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let window, let contentView = window.contentView else { return }
        for rect in dividerRects(in: contentView) {
            addCursorRect(convert(rect, from: contentView), cursor: dividerCursor)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    private func dividerRects(in contentView: NSView) -> [NSRect] {
        splitViews(in: contentView).flatMap { splitView in
            (0..<max(splitView.subviews.count - 1, 0)).map { index in
                let dividerThickness = splitView.dividerThickness
                let previous = splitView.subviews[index].frame
                let rect: NSRect
                if splitView.isVertical {
                    rect = NSRect(
                        x: previous.maxX,
                        y: splitView.bounds.minY,
                        width: dividerThickness,
                        height: splitView.bounds.height
                    )
                } else {
                    rect = NSRect(
                        x: splitView.bounds.minX,
                        y: previous.maxY,
                        width: splitView.bounds.width,
                        height: dividerThickness
                    )
                }
                return splitView.convert(rect, to: contentView).insetBy(dx: -7, dy: -2)
            }
        }
    }

    func restoreSavedDividerPositions() {
        guard !isRestoringDividerPositions else { return }
        guard let contentView = window?.contentView,
              let positions = dividerDefaults.array(forKey: dividerPositionsKey) as? [Double] else {
            return
        }
        guard let splitView = primarySplitView(in: contentView) else { return }
        isRestoringDividerPositions = true
        defer { isRestoringDividerPositions = false }
        for (index, position) in positions.enumerated() where index < splitView.subviews.count - 1 {
            splitView.setPosition(CGFloat(position), ofDividerAt: index)
        }
    }

    private func saveDividerPositions() {
        guard let contentView = window?.contentView else { return }
        guard let splitView = primarySplitView(in: contentView) else { return }
        let positions = (0..<max(splitView.subviews.count - 1, 0)).map {
            Double(splitView.subviews[$0].frame.maxX)
        }
        dividerDefaults.set(positions, forKey: dividerPositionsKey)
    }

    private func primarySplitView(in view: NSView) -> NSSplitView? {
        splitViews(in: view).first { $0.subviews.count >= 3 }
            ?? splitViews(in: view).first
    }

    private func splitViews(in view: NSView?) -> [NSSplitView] {
        guard let view else { return [] }
        var views: [NSView] = [view]
        for subview in view.subviews {
            views.append(contentsOf: splitViews(in: subview))
        }
        return views.compactMap { $0 as? NSSplitView }
    }
}

final class ResizeDividerNSView: NSView {
    private static let appleSplitCursor: NSCursor = {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(true)

            // Outline / Shadow for contrast on light/dark backgrounds
            NSColor.white.setStroke()
            NSColor.white.setFill()
            
            // White background vertical bar
            let whiteBar = NSRect(x: 8.5, y: 2.5, width: 3, height: 15)
            whiteBar.fill()

            // Black center vertical bar
            NSColor.black.setFill()
            let blackBar = NSRect(x: 9.25, y: 3.5, width: 1.5, height: 13)
            blackBar.fill()

            // Left arrow <
            let leftArrow = NSBezierPath()
            leftArrow.move(to: NSPoint(x: 6.5, y: 10))
            leftArrow.line(to: NSPoint(x: 2, y: 10))
            leftArrow.line(to: NSPoint(x: 5, y: 13))
            leftArrow.move(to: NSPoint(x: 2, y: 10))
            leftArrow.line(to: NSPoint(x: 5, y: 7))
            
            NSColor.white.setStroke()
            leftArrow.lineWidth = 3.0
            leftArrow.lineCapStyle = .round
            leftArrow.lineJoinStyle = .round
            leftArrow.stroke()

            NSColor.black.setStroke()
            leftArrow.lineWidth = 1.5
            leftArrow.stroke()

            // Right arrow >
            let rightArrow = NSBezierPath()
            rightArrow.move(to: NSPoint(x: 13.5, y: 10))
            rightArrow.line(to: NSPoint(x: 18, y: 10))
            rightArrow.line(to: NSPoint(x: 15, y: 13))
            rightArrow.move(to: NSPoint(x: 18, y: 10))
            rightArrow.line(to: NSPoint(x: 15, y: 7))

            NSColor.white.setStroke()
            rightArrow.lineWidth = 3.0
            rightArrow.lineCapStyle = .round
            rightArrow.lineJoinStyle = .round
            rightArrow.stroke()

            NSColor.black.setStroke()
            rightArrow.lineWidth = 1.5
            rightArrow.stroke()

            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.appleSplitCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.appleSplitCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        Self.appleSplitCursor.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        let lineRect = NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        lineRect.fill()
    }
}

struct NativeSplitView: NSViewControllerRepresentable {
    let sidebar: AnyView
    let content: AnyView
    let detail: AnyView

    func makeNSViewController(context: Context) -> NativeSplitViewController {
        NativeSplitViewController(sidebar: sidebar, content: content, detail: detail)
    }

    func updateNSViewController(_ controller: NativeSplitViewController, context: Context) {
        controller.update(sidebar: sidebar, content: content, detail: detail)
    }
}

final class NativeSplitViewController: NSSplitViewController {
    private let delegate = NativeSplitViewDelegate()
    private var hostingControllers: [NSHostingController<AnyView>]

    init(sidebar: AnyView, content: AnyView, detail: AnyView) {
        hostingControllers = [
            NSHostingController(rootView: sidebar),
            NSHostingController(rootView: content),
            NSHostingController(rootView: detail)
        ]
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = delegate
        splitView.autosaveName = "PlagadeonNotesColumns"

        let sidebarItem = NSSplitViewItem(viewController: hostingControllers[0])
        sidebarItem.minimumThickness = 160
        let contentItem = NSSplitViewItem(viewController: hostingControllers[1])
        contentItem.minimumThickness = 200
        let detailItem = NSSplitViewItem(viewController: hostingControllers[2])
        detailItem.minimumThickness = 320
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(detailItem)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(sidebar: AnyView, content: AnyView, detail: AnyView) {
        hostingControllers[0].rootView = sidebar
        hostingControllers[1].rootView = content
        hostingControllers[2].rootView = detail
    }
}

private final class NativeSplitViewDelegate: NSObject, NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        splitView.subviews[dividerIndex].frame.insetBy(dx: -5, dy: 0)
    }

    func splitView(_ splitView: NSSplitView, effectiveRectForDrawnRect proposedEffectiveRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        proposedEffectiveRect.insetBy(dx: -5, dy: 0)
    }
}

@MainActor
final class NoteTextEditorController: ObservableObject {
    weak var textView: NSTextView?

    func apply(marker: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selectedText = (textView.string as NSString).substring(with: range)
        let replacement: String
        if selectedText.isEmpty {
            replacement = "\(marker)\(marker)"
        } else if selectedText.hasPrefix(marker), selectedText.hasSuffix(marker), selectedText.count >= marker.count * 2 {
            replacement = String(selectedText.dropFirst(marker.count).dropLast(marker.count))
        } else {
            replacement = "\(marker)\(selectedText)\(marker)"
        }
        textView.replaceCharacters(in: range, with: replacement)
        let cursorLocation = range.location + (selectedText.isEmpty ? marker.count : replacement.count)
        textView.setSelectedRange(NSRange(location: cursorLocation, length: selectedText.isEmpty ? 0 : replacement.count))
        textView.didChangeText()
        textView.window?.makeFirstResponder(textView)
    }

    func prefixSelectedLines(with prefix: String) {
        guard let textView else { return }
        let string = textView.string as NSString
        let selectedRange = textView.selectedRange()
        let lineStart = string.lineRange(for: NSRange(location: selectedRange.location, length: 0)).location
        let selectedEnd = min(string.length, selectedRange.location + selectedRange.length)
        let lineEnd = string.lineRange(for: NSRange(location: selectedEnd, length: 0)).upperBound
        let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        let lines = string.substring(with: lineRange)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : prefix + line
            }
            .joined(separator: "\n")
        textView.replaceCharacters(in: lineRange, with: lines)
        textView.setSelectedRange(NSRange(location: lineStart, length: lines.count))
        textView.didChangeText()
        textView.window?.makeFirstResponder(textView)
    }
}

struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: NoteTextEditorController

    final class PassThroughScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PassThroughScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.delegate = context.coordinator
        controller.textView = textView
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.textView = textView
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let controller: NoteTextEditorController

        init(text: Binding<String>, controller: NoteTextEditorController) {
            _text = text
            self.controller = controller
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

struct NoteEditor: View {
    let note: Note
    @ObservedObject var store: NoteStore
    @State private var showingImporter = false
    @State private var showingCategoryPicker = false
    @State private var newCategoryName = ""
    @StateObject private var textEditorController = NoteTextEditorController()
    @State private var editorWidth: CGFloat = 680

    private var categoryLabel: String {
        let normalized = note.folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Ohne Kategorie" : normalized
    }

    private var availableCategories: [String] {
        let categories = Set(
            store.notes
                .map { $0.folder.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return categories.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var inlineAttachments: [Attachment] {
        if !note.contentBlocks.isEmpty {
            let attachmentsByID = Dictionary(uniqueKeysWithValues: note.attachments.map { ($0.id, $0) })
            return note.contentBlocks.compactMap { block in
                guard case .attachment(let attachmentID) = block else { return nil }
                return attachmentsByID[attachmentID]
            }
        }
        if note.sourceID?.hasPrefix("applenotes:") == true {
            return note.attachments
        }
        return note.attachments.filter { attachment in
            note.body.localizedCaseInsensitiveContains(attachment.name) ||
            note.body.localizedCaseInsensitiveContains(attachment.path)
        }
    }

    private var remainingAttachments: [Attachment] {
        let inlineIDs = Set(inlineAttachments.map(\.id))
        return note.attachments.filter { !inlineIDs.contains($0.id) }
    }

    private var attachmentsByID: [UUID: Attachment] {
        Dictionary(uniqueKeysWithValues: note.attachments.map { ($0.id, $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Titel", text: Binding(
                    get: { note.title },
                    set: { update(title: $0) }
                ))
                .font(.largeTitle)
                .textFieldStyle(.plain)

                HStack {
                    Button {
                        showingCategoryPicker = true
                    } label: {
                        Label(categoryLabel, systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    TextField("Tags, durch Komma getrennt", text: Binding(
                        get: { note.tags.joined(separator: ", ") },
                        set: { update(tags: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(appSelectedRowColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 220, alignment: .leading)
                }

                if note.contentBlocks.isEmpty {
                    NoteTextEditor(text: Binding(
                        get: { note.body },
                        set: { update(body: $0) }
                    ), controller: textEditorController)
                    .frame(minHeight: max(260, editorHeight(for: note.body)))
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(note.contentBlocks.enumerated()), id: \.offset) { index, block in
                            switch block {
                            case .text(let value):
                                NoteTextEditor(text: Binding(
                                    get: { value },
                                    set: { updateTextBlock(at: index, text: $0) }
                                ), controller: textEditorController)
                                .frame(minHeight: editorHeight(for: value))
                            case .attachment(let attachmentID):
                                if let attachment = attachmentsByID[attachmentID] {
                                    AttachmentPreview(attachment: attachment, url: store.url(for: attachment))
                                }
                            }
                        }
                    }
                }

                if !remainingAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Anhänge")
                            .font(.headline)
                        ForEach(remainingAttachments) { attachment in
                            AttachmentPreview(attachment: attachment, url: store.url(for: attachment))
                                .id(attachment.id)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            editorWidth = max(proxy.size.width - 24, 320)
                        }
                        .onChange(of: proxy.size.width) { newValue in
                            editorWidth = max(newValue - 24, 320)
                        }
                }
            )
        }
        .background(appEggshellColor)
        .toolbar {
            Menu {
                Button("Fett  **Text**") { textEditorController.apply(marker: "**") }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Kursiv  _Text_") { textEditorController.apply(marker: "_") }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                Button("Überschrift  # Überschrift") { textEditorController.prefixSelectedLines(with: "# ") }
                Button("Aufzählung  - Punkt") { textEditorController.prefixSelectedLines(with: "- ") }
                Button("Nummerierte Liste  1. Punkt") { textEditorController.prefixSelectedLines(with: "1. ") }
                Button("Code  `Code`") { textEditorController.apply(marker: "`") }
            } label: {
                Label("Markdown", systemImage: "textformat")
            }
            Button(action: { showingImporter = true }) {
                Label("Anhang hinzufügen", systemImage: "paperclip")
            }
            Menu {
                Button("Markdown exportieren") { store.exportMarkdown(note) }
                Button("HTML exportieren") { store.exportHTML(note) }
                Button("PDF exportieren") { store.exportPDF(note) }
                Button("JSON-Backup exportieren") { store.exportBackup() }
            } label: {
                Label("Exportieren", systemImage: "square.and.arrow.up")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            urls.forEach { store.importAttachment(from: $0, into: note) }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Kategorie auswählen")
                    .font(.title3.weight(.semibold))

                Button("Ohne Kategorie") {
                    update(folder: "")
                    showingCategoryPicker = false
                }
                .buttonStyle(.bordered)

                List(availableCategories, id: \.self) { category in
                    Button(action: {
                        update(folder: category)
                        showingCategoryPicker = false
                    }) {
                        HStack {
                            Text(category)
                            Spacer()
                            if category == note.folder.trimmingCharacters(in: .whitespacesAndNewlines) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 180)

                HStack(spacing: 8) {
                    TextField("Neue Kategorie", text: $newCategoryName)
                        .textFieldStyle(.roundedBorder)
                    Button("Anlegen") {
                        let normalized = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalized.isEmpty else { return }
                        update(folder: normalized)
                        newCategoryName = ""
                        showingCategoryPicker = false
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack {
                    Spacer()
                    Button("Schließen") {
                        showingCategoryPicker = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(minWidth: 420, minHeight: 380)
            .onAppear {
                newCategoryName = ""
            }
        }
    }

    private func update(title: String? = nil, body: String? = nil, folder: String? = nil, tags: String? = nil) {
        var updated = note
        if let title { updated.title = title }
        if let body { updated.body = body }
        if let folder { updated.folder = folder.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let tags {
            updated.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        updated.modifiedAt = Date()
        store.update(updated)
    }

    private func updateTextBlock(at index: Int, text: String) {
        guard index >= 0, index < note.contentBlocks.count else { return }
        guard case .text = note.contentBlocks[index] else { return }
        var updated = note
        updated.contentBlocks[index] = .text(text)
        updated.body = updated.contentBlocks.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        updated.modifiedAt = Date()
        store.update(updated)
    }

    private func editorHeight(for text: String) -> CGFloat {
        let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if visible.isEmpty {
            return 48
        }

        let targetWidth = max(editorWidth - 12, 280)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: targetWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return max(68, ceil(rect.height) + 34)
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment
    let url: URL

    private var contentType: UTType? {
        UTType(filenameExtension: url.pathExtension)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = NSImage(contentsOf: url) {
                Button(action: openAttachment) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: 460, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Bild öffnen")
            } else if contentType?.conforms(to: .movie) == true {
                VideoAttachmentView(url: url)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if contentType?.conforms(to: .audio) == true {
                AudioPlayer(url: url)
            } else {
                Button(action: { NSWorkspace.shared.open(url) }) {
                    Label(attachment.name, systemImage: "doc")
                }
                .buttonStyle(.link)
            }

            if !FileManager.default.fileExists(atPath: url.path) {
                Label("Datei nicht verfügbar", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func openAttachment() {
        NSWorkspace.shared.open(url)
    }
}

struct VideoAttachmentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if let player = nsView.player,
           let currentItem = player.currentItem,
           let currentURL = (currentItem.asset as? AVURLAsset)?.url,
           currentURL == url {
            return
        }
        nsView.player?.pause()
        nsView.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

struct AudioPlayer: View {
    let url: URL
    @State private var player: AVAudioPlayer?

    var body: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .lineLimit(1)
            Spacer()
            Button(action: togglePlayback) {
                Image(systemName: player?.isPlaying == true ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
        }
        .task {
            player = try? AVAudioPlayer(contentsOf: url)
        }
        .onDisappear {
            player?.stop()
            player = nil
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }
}
