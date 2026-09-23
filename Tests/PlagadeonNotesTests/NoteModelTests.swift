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

    @MainActor
    @Test
    func appleNotesImportUpdatesRenamedAndMovedNote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storeFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: storeFolder)
        }

        let databaseURL = folder.appendingPathComponent("NoteStore.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, """
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
            Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZTITLE1 TEXT, ZTITLE2 TEXT, ZNAME TEXT,
            ZSNIPPET TEXT, ZFOLDER INTEGER, ZMODIFICATIONDATE1 REAL, ZIDENTIFIER TEXT,
            ZNOTEDATA INTEGER, ZMARKEDFORDELETION INTEGER, ZNOTE INTEGER, ZFILENAME TEXT,
            ZMEDIA INTEGER, ZCREATIONDATE REAL
        );
        CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZDATA BLOB);
        """, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, """
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTITLE2, ZNAME) VALUES (1, 15, 'Privat', 'Privat');
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTITLE1, ZSNIPPET, ZFOLDER, ZMODIFICATIONDATE1, ZIDENTIFIER)
        VALUES (2, 12, 'Alter Titel', 'Inhalt', 1, 1, 'stable-note-id');
        """, nil, nil, nil) == SQLITE_OK)

        let store = NoteStore(baseDirectory: storeFolder)
        #expect(store.importSnapshot(from: folder).imported == 1)

        #expect(sqlite3_exec(database, """
        UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE2 = 'Archiv' WHERE Z_PK = 1;
        UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE1 = 'Neuer Titel', ZMODIFICATIONDATE1 = 2 WHERE Z_PK = 2;
        """, nil, nil, nil) == SQLITE_OK)

        let report = store.importSnapshot(from: folder)
        let updated = try #require(store.notes.first(where: { $0.sourceID == "applenotes:stable-note-id" }))
        #expect(report.updated == 1)
        #expect(report.duplicates == 0)
        #expect(updated.title == "Neuer Titel")
        #expect(updated.folder == "Archiv")
    }

    @Test
    func exportersKeepNoteContentAndAttachmentLinks() throws {
        let attachmentID = UUID()
        let note = Note(
            title: "A&B",
            body: "<Text>",
            attachments: [Attachment(id: attachmentID, name: "Bild.png", path: "asset.png")],
            contentBlocks: [.text("Einleitung"), .attachment(attachmentID), .text("Schluss")]
        )

        #expect(NoteExporter.markdown(note).contains("![Bild.png](attachments/asset.png)"))
        #expect(NoteExporter.html(note).contains("A&amp;B"))
        #expect(NoteExporter.html(note).contains("<img src=\"attachments/asset.png\""))
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

    @Test
    func protobufFieldReaderPreservesRepeatedFieldsAndWireValues() {
        let data = Data([
            8, 42,
            18, 2, 65, 66,
            18, 1, 67,
            29, 1, 2, 3, 4
        ])

        let fields = AppleNotesSnapshotInspector.protobufFields(in: data)

        #expect(fields == [
            ProtobufField(number: 1, value: .varint(42)),
            ProtobufField(number: 2, value: .lengthDelimited(Data([65, 66]))),
            ProtobufField(number: 2, value: .lengthDelimited(Data([67]))),
            ProtobufField(number: 3, value: .fixed32(Data([1, 2, 3, 4])))
        ])
    }

    @Test
    func realSnapshotDiagnosticsForKnownAppleNotesExamples() throws {
        let env = ProcessInfo.processInfo.environment
        guard let snapshotPath = env["PLAGADEON_REAL_SNAPSHOT"], !snapshotPath.isEmpty else {
            return
        }

        let folder = URL(fileURLWithPath: snapshotPath, isDirectory: true)
        let candidates = AppleNotesSnapshotInspector.noteCandidates(in: folder)
        let identifiers = [
            "5EBF3FAB-6D28-4DE0-B39B-6CB1FB796F43",
            "70715E90-AE61-413C-8A34-567F40E4614D",
            "61A5AB6F-F2BE-4761-BD5E-415FB84A8936"
        ]

        for identifier in identifiers {
            let sourceID = "applenotes:\(identifier)"
            let candidate = try #require(candidates.first(where: { $0.sourceID == sourceID }))

            let attachmentCount = candidate.contentBlocks.reduce(into: 0) { count, block in
                if case .attachment = block {
                    count += 1
                }
            }
            #expect(attachmentCount == candidate.attachmentSources.count)

            let hasInterleaving = hasInlineInterleaving(candidate.contentBlocks)
            print("[REAL-SNAPSHOT] \(sourceID) title=\(candidate.title) blocks=\(candidate.contentBlocks.count) attachments=\(candidate.attachmentSources.count) interleaved=\(hasInterleaving)")
            print("[REAL-SNAPSHOT-SEQUENCE] \(blockSummary(candidate.contentBlocks))")

            if sourceID == "applenotes:5EBF3FAB-6D28-4DE0-B39B-6CB1FB796F43" {
                #expect(candidate.body.localizedCaseInsensitiveContains("Inhaltsverzeichnis"))
                let filenamesByKey = Dictionary(uniqueKeysWithValues: candidate.attachmentSources.map { ($0.sourceKey, $0.filename) })
                let attachmentOrder = candidate.contentBlocks.compactMap { block -> String? in
                    guard case .attachment(let sourceKey) = block else { return nil }
                    return filenamesByKey[sourceKey] ?? "(unbekannt)"
                }
                print("[REAL-SNAPSHOT-ATTACHMENT-ORDER] \(attachmentOrder.joined(separator: " | "))")
            }
        }
    }

    @Test
    func exportersPreserveInlineBlockOrder() {
        let attachmentID = UUID()
        let note = Note(
            title: "Inline",
            body: "",
            attachments: [Attachment(id: attachmentID, name: "bild.jpg", path: "x.jpg")],
            contentBlocks: [.text("Alpha"), .attachment(attachmentID), .text("Omega")]
        )

        let markdown = NoteExporter.markdown(note)
        let html = NoteExporter.html(note)

        #expect(markdown.contains("Alpha\n\n![bild.jpg](attachments/x.jpg)\n\nOmega"))
        #expect(html.contains("<p>Alpha</p>"))
        #expect(html.contains("<img src=\"attachments/x.jpg\""))
        #expect(html.contains("<p>Omega</p>"))
    }

    @MainActor
    @Test
    func realSnapshotImportPersistsInterleavedBlocks() throws {
        let env = ProcessInfo.processInfo.environment
        guard let snapshotPath = env["PLAGADEON_REAL_SNAPSHOT"], !snapshotPath.isEmpty else {
            return
        }

        let tempStore = FileManager.default.temporaryDirectory
            .appendingPathComponent("plagadeon-test-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempStore, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempStore) }

        let store = NoteStore(baseDirectory: tempStore)
        let report = store.importSnapshot(from: URL(fileURLWithPath: snapshotPath, isDirectory: true))
        #expect(report.imported > 0)

        let targets = [
            "applenotes:5EBF3FAB-6D28-4DE0-B39B-6CB1FB796F43": 8,
            "applenotes:70715E90-AE61-413C-8A34-567F40E4614D": 1,
            "applenotes:61A5AB6F-F2BE-4761-BD5E-415FB84A8936": 3
        ]

        for (sourceID, expectedAttachments) in targets {
            let note = try #require(store.notes.first(where: { $0.sourceID == sourceID }))
            let attachmentBlocks = note.contentBlocks.reduce(into: 0) { count, block in
                if case .attachment = block {
                    count += 1
                }
            }
            #expect(attachmentBlocks == expectedAttachments)
            #expect(hasInlineInterleaving(note.contentBlocks))
            print("[REAL-IMPORT] \(sourceID) attachments=\(attachmentBlocks) sequence=\(persistedBlockSummary(note.contentBlocks))")
        }
    }

    @MainActor
    @Test
    func realSnapshotReimportDoesNotReportUpdates() throws {
        let env = ProcessInfo.processInfo.environment
        guard let snapshotPath = env["PLAGADEON_REAL_SNAPSHOT"], !snapshotPath.isEmpty else {
            return
        }

        let tempStore = FileManager.default.temporaryDirectory
            .appendingPathComponent("plagadeon-reimport-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempStore, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempStore) }

        let store = NoteStore(baseDirectory: tempStore)
        let snapshot = URL(fileURLWithPath: snapshotPath, isDirectory: true)
        #expect(store.importSnapshot(from: snapshot).imported > 0)
        let initialNotes = Dictionary(uniqueKeysWithValues: store.notes.compactMap { note in
            note.sourceID.map { ($0, note) }
        })

        let report = store.importSnapshot(from: snapshot)
        let updatedSourceIDs = store.notes.compactMap { note -> String? in
            guard let sourceID = note.sourceID, initialNotes[sourceID] != note else { return nil }
            return sourceID
        }
        #expect(
            report.updated == 0 && report.imported == 0 && updatedSourceIDs.isEmpty,
            "Importiert: \(report.imported), aktualisiert: \(report.updated), Quell-IDs: \(updatedSourceIDs)"
        )
    }

    private func hasInlineInterleaving(_ blocks: [SnapshotContentBlock]) -> Bool {
        guard blocks.count >= 3 else { return false }
        for index in 1..<(blocks.count - 1) {
            if case .attachment = blocks[index],
               case .text = blocks[index - 1],
               case .text = blocks[index + 1] {
                return true
            }
        }
        return false
    }

    private func hasInlineInterleaving(_ blocks: [NoteContentBlock]) -> Bool {
        guard blocks.count >= 3 else { return false }
        for index in 1..<(blocks.count - 1) {
            if case .attachment = blocks[index],
               case .text = blocks[index - 1],
               case .text = blocks[index + 1] {
                return true
            }
        }
        return false
    }

    private func blockSummary(_ blocks: [SnapshotContentBlock]) -> String {
        blocks.map { block in
            switch block {
            case .text(let value):
                return "T(\(min(value.count, 40)))"
            case .attachment:
                return "A"
            }
        }
        .joined(separator: " -> ")
    }

    private func persistedBlockSummary(_ blocks: [NoteContentBlock]) -> String {
        blocks.map { block in
            switch block {
            case .text(let value):
                return "T(\(min(value.count, 40)))"
            case .attachment:
                return "A"
            }
        }
        .joined(separator: " -> ")
    }
}
