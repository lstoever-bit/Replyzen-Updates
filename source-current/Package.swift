// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Replyzen",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(
            url: "https://github.com/canopas/rich-editor-swiftui.git",
            exact: "1.1.1"
        )
    ],
    targets: [
        .executableTarget(
            name: "Replyzen",
            dependencies: [
                .product(name: "RichEditorSwiftUI", package: "rich-editor-swiftui")
            ],
            path: "app",
            exclude: ["Info.plist", "Resources"]
        )
    ]
)
