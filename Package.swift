// swift-tools-version: 5.9
// Swift Package für „reichi Sync“.
//
// - `ReichiSyncCore` enthält die plattformunabhängige Synchronisierungslogik
//   (WebDAV-Client, Drei-Wege-Abgleich, Persistenz, Transfers). Sie wird auf
//   macOS und Linux gebaut und getestet.
// - `ReichiSync` ist die native macOS-App (SwiftUI/AppKit). Sie wird nur auf
//   macOS gebaut. Das eigentliche App-Bundle entsteht über das XcodeGen-Projekt
//   (`project.yml`) oder über `Scripts/build-app.sh`.
import PackageDescription

var products: [Product] = [
    .library(name: "ReichiSyncCore", targets: ["ReichiSyncCore"]),
]
var targets: [Target] = [
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "ReichiSyncCore",
        dependencies: ["CSQLite"],
        path: "Sources/ReichiSyncCore",
        swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .testTarget(
        name: "ReichiSyncCoreTests",
        dependencies: ["ReichiSyncCore"],
        path: "Tests/ReichiSyncCoreTests",
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "ReichiSync", targets: ["ReichiSync"]))
targets.append(
    .executableTarget(
        name: "ReichiSync",
        dependencies: ["ReichiSyncCore"],
        path: "Sources/ReichiSyncApp",
        exclude: ["Info.plist", "ReichiSync.entitlements", "Resources/Assets.xcassets"],
        resources: [.process("Resources/Localizable.xcstrings")],
        swiftSettings: [.enableUpcomingFeature("StrictConcurrency")],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SwiftUI"),
            .linkedFramework("ServiceManagement"),
            .linkedFramework("UserNotifications"),
            .linkedFramework("CoreServices"),
            .linkedFramework("Network"),
            .linkedFramework("Security"),
        ]
    )
)
#endif

let package = Package(
    name: "ReichiSync",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
