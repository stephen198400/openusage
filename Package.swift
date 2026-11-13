// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyUsage",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MyUsage", targets: ["MyUsageApp"]),
        .executable(name: "myusage-cli", targets: ["MyUsageCLI"])
    ],
    dependencies: [
        // The de-facto standard recorder + global hotkey for Mac apps (System Settings-style field).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        // In-app auto-updates (appcast + EdDSA-signed downloads). 2.9.4 fixes the update window opening
        // behind other apps for menu-bar (dockless) apps (sparkle-project/Sparkle#2889).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
        // Anonymous usage analytics and mandatory crash reporting (official first-party Swift SDK).
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.62.0")
    ],
    targets: [
        .target(
            name: "MyUsage",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/MyUsage",
            resources: [
                .copy("Resources/ProviderIcons"),
                .copy("Resources/pricing_supplement.json"),
                .copy("Resources/pricing_litellm_snapshot.json"),
                .copy("Resources/pricing_models_dev_snapshot.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "MyUsageApp",
            dependencies: ["MyUsage"],
            path: "Sources/MyUsageApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "MyUsageCLI",
            dependencies: ["MyUsage"],
            path: "Sources/MyUsageCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MyUsageTests",
            dependencies: ["MyUsage"],
            path: "Tests/MyUsageTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MyUsageCLITests",
            dependencies: ["MyUsageCLI"],
            path: "Tests/MyUsageCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
