// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

var targets: [Target] = [
    .executableTarget(
        name: "macpdf-ocr-mcp"
    )
]

if FileManager.default.fileExists(atPath: "LocalTests/Unit/macpdf-ocr-mcpTests") {
    targets.append(
        .testTarget(
            name: "macpdf-ocr-mcpTests",
            dependencies: ["macpdf-ocr-mcp"],
            path: "LocalTests/Unit/macpdf-ocr-mcpTests"
        )
    )
}

let package = Package(
    name: "macpdf-ocr-mcp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "macpdf-ocr-mcp", targets: ["macpdf-ocr-mcp"])
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
