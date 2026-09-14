import Foundation

let projectDirectory = "__PROJECT_DIR__"
let binaryPath = "\(projectDirectory)/.build/arm64-apple-macosx/debug/PlagadeonNotes"
let buildLogPath = "/tmp/plagadeon-notes-build.log"

func modificationDate(at path: String) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
}

func newestSourceDate() -> Date {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: "\(projectDirectory)/Sources"),
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return modificationDate(at: "\(projectDirectory)/Package.swift") ?? .distantPast
    }
    var newest = modificationDate(at: "\(projectDirectory)/Package.swift") ?? .distantPast
    for case let url as URL in enumerator {
          if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              date > newest {
            newest = date
        }
    }
    return newest
}

let binaryURL = URL(fileURLWithPath: binaryPath)
let needsBuild = !FileManager.default.isExecutableFile(atPath: binaryPath) ||
    (modificationDate(at: binaryPath).map { newestSourceDate() > $0 } ?? true)

if needsBuild {
    let logURL = URL(fileURLWithPath: buildLogPath)
    FileManager.default.createFile(atPath: buildLogPath, contents: nil)
    let logHandle = try? FileHandle(forWritingTo: logURL)
    let build = Process()
    build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    build.arguments = ["build", "--package-path", projectDirectory, "-c", "debug"]
    build.standardOutput = logHandle
    build.standardError = logHandle
    do {
        try build.run()
        build.waitUntilExit()
        try? logHandle?.close()
        if build.terminationStatus != 0 {
            let alert = Process()
            alert.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            alert.arguments = ["-e", "display alert \"Plagadeon Notes\" message \""]
            try? alert.run()
            exit(build.terminationStatus)
        }
    } catch {
        exit(1)
    }
}

let app = Process()
app.executableURL = binaryURL
app.currentDirectoryURL = URL(fileURLWithPath: projectDirectory)
do {
    try app.run()
    app.waitUntilExit()
    exit(app.terminationStatus)
} catch {
    exit(1)
}
