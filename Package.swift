// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Mailr",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MailCore", targets: ["MailCore"]),
        .executable(name: "Mailr", targets: ["Mailr"]),
        .executable(name: "MailrServer", targets: ["MailrServer"]),
        .executable(name: "mailr-import", targets: ["MailrImport"])
    ],
    targets: [
        .target(
            name: "MailCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "Mailr",
            dependencies: ["MailCore"],
            exclude: ["Assets.xcassets"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "MailrServer",
            dependencies: ["MailCore"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "MailrImport",
            dependencies: ["MailCore"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "MailCoreTests",
            dependencies: ["MailCore"]
        )
    ]
)
