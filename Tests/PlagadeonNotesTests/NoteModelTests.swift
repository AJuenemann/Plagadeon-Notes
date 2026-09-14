import Foundation
import SQLite3
import PDFKit
import Testing
@testable import PlagadeonNotes

struct NoteModelTests {
    @Test
    func noteRoundTripsThroughJSON() throws {
        var note = Note(title: "Reise", body: "Packliste")
        note.attachments = [Attachment(name: "karte.pdf", path: "karte.pdf")]

        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(Note.self, from: data)

        #expect(decoded == note)
        #expect(decoded.attachments.first?.path == "karte.pdf")
    }

    @Test
    func snapshotInspectorFindsSQLiteTables() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let databaseURL = folder.appendingPathComponent("snapshot.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE notes (id TEXT, title TEXT)", nil, nil, nil) == SQLITE_OK)

        let inspection = AppleNotesSnapshotInspector.inspect(folder)

        #expect(inspection.count == 1)
        #expect(inspection.first?.tables.map(\.name) == ["notes"])
        #expect(inspection.first?.tables.first?.columns == ["id", "title"])
        #expect(inspection.first?.tables.first?.rowCount == 0)
        #expect(inspection.first?.tables.first?.role == .note)
    }

    @Test
    func snapshotInspectorReadsTextNoteCandidates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let databaseURL = folder.appendingPathComponent("snapshot.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE notes (title TEXT, body TEXT)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "INSERT INTO notes VALUES ('Einkauf', 'Milch')", nil, nil, nil) == SQLITE_OK)

        let candidates = AppleNotesSnapshotInspector.noteCandidates(in: folder)

        #expect(candidates.count == 1)
        #expect(candidates.first?.title == "Einkauf")
        #expect(candidates.first?.body == "Milch")
    }

    @Test
    func exportersKeepNoteContentAndAttachmentLinks() throws {
        let note = Note(
            title: "A&B",
            body: "<Text>",
            attachments: [Attachment(name: "Bild.png", path: "asset.png")]
        )

        #expect(NoteExporter.markdown(note).contains("[Bild.png](attachments/asset.png)"))
        #expect(NoteExporter.html(note).contains("A&amp;B"))
        #expect(NoteExporter.html(note).contains("&lt;Text&gt;"))
        let pdfData = try #require(NoteExporter.pdfData(note))
        #expect(PDFDocument(data: pdfData)?.pageCount == 1)
    }

    @Test
    func protobufTextExtractorFindsNestedText() {
        // Field 2 (tag 18) -> Field 3 (tag 26) -> Field 2 (tag 18) -> "Hallo Welt"
        let innerText = "Hallo Welt".data(using: .utf8)!
        var f2Inner = Data([18, UInt8(innerText.count)])
        f2Inner.append(innerText)

        var f3 = Data([26, UInt8(f2Inner.count)])
        f3.append(f2Inner)

        var top = Data([18, UInt8(f3.count)])
        top.append(f3)

        let extracted = AppleNotesSnapshotInspector.extractProtobufText(top)
        #expect(extracted == "Hallo Welt")
    }
}
