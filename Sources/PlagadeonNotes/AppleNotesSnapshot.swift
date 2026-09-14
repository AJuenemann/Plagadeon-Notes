import Foundation
import SQLite3
import zlib

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

struct SnapshotNoteCandidate {
    let title: String
    let body: String
    let folder: String
    let attachments: [URL]
    let modifiedAt: Date
    let sourceID: String
}

struct SnapshotImportReport {
    let candidates: Int
    let imported: Int
    let duplicates: Int
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
        var noteAttachments: [Int64: [URL]] = [:]
        let attachQuery = """
        SELECT a.ZNOTE, a.ZIDENTIFIER, a.ZFILENAME, m.ZIDENTIFIER, m.ZFILENAME
        FROM ZICCLOUDSYNCINGOBJECT a
        LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON a.ZMEDIA = m.Z_PK
        WHERE a.Z_ENT = 5;
        """
        if sqlite3_prepare_v2(database, attachQuery, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let notePK = sqlite3_column_int64(statement, 0)
                let aIdent = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let aFilename = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let mIdent = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                let mFilename = sqlite3_column_text(statement, 4).map { String(cString: $0) }

                let filename = mFilename ?? aFilename
                let ident = mIdent ?? aIdent

                if let filename, let fileURL = findMediaFile(baseFolder: baseFolder, identifier: ident, filename: filename) {
                    if noteAttachments[notePK] == nil {
                        noteAttachments[notePK] = []
                    }
                    noteAttachments[notePK]?.append(fileURL)
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
                if let blobPointer = sqlite3_column_blob(statement, 6) {
                    let blobBytes = sqlite3_column_bytes(statement, 6)
                    let data = Data(bytes: blobPointer, count: Int(blobBytes))
                    if let decompressed = decompressGzip(data) {
                        extractedText = extractProtobufText(decompressed)
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

                guard !body.isEmpty || !(noteAttachments[pk] ?? []).isEmpty else { continue }

                let folderName = folders[folderPK] ?? "Notizen"
                let modifiedDate = modTimestamp > 0
                    ? Date(timeIntervalSinceReferenceDate: modTimestamp)
                    : Date()

                candidates.append(SnapshotNoteCandidate(
                    title: title,
                    body: body,
                    folder: folderName,
                    attachments: noteAttachments[pk] ?? [],
                    modifiedAt: modifiedDate,
                    sourceID: "applenotes:\(identifier)"
                ))
            }
            sqlite3_finalize(statement)
        }

        return candidates
    }

    private static func findMediaFile(baseFolder: URL, identifier: String?, filename: String) -> URL? {
        let fileManager = FileManager.default

        // Direct accounts media check
        if let identifier {
            let accountsURL = baseFolder.appendingPathComponent("Accounts", isDirectory: true)
            if let accountDirs = try? fileManager.contentsOfDirectory(at: accountsURL, includingPropertiesForKeys: nil) {
                for accountDir in accountDirs {
                    let mediaDir = accountDir.appendingPathComponent("Media/\(identifier)", isDirectory: true)
                    if let genDirs = try? fileManager.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) {
                        for genDir in genDirs {
                            let candidate = genDir.appendingPathComponent(filename)
                            if fileManager.fileExists(atPath: candidate.path) {
                                return candidate
                            }
                        }
                    }
                    let directCandidate = mediaDir.appendingPathComponent(filename)
                    if fileManager.fileExists(atPath: directCandidate.path) {
                        return directCandidate
                    }
                }
            }
        }

        // Deep search in baseFolder if direct search misses
        if let enumerator = fileManager.enumerator(at: baseFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == filename {
                    return fileURL
                }
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
                attachments: [],
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
