// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlagadeonNotes",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PlagadeonNotes", targets: ["PlagadeonNotes"])
    ],
    targets: [
        .executableTarget(
            name: "PlagadeonNotes",
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "PlagadeonNotesTests",
            dependencies: ["PlagadeonNotes"],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
