// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Samogon",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Samogon", targets: ["Samogon"])
    ],
    targets: [
        .executableTarget(
            name: "Samogon",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision")
            ]
        )
    ]
)
