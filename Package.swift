// swift-tools-version: 6.2
import PackageDescription

// Foundation/AVFoundation regression tests can run without an iOS simulator.
let package = Package(
    name: "TonkunstCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "TonkunstCore",
            path: "Tonkunst",
            exclude: ["TonkunstApp.swift", "Info.plist", "Views", "Resources/Assets.xcassets", "Resources/PrivacyInfo.xcprivacy", "Resources/InfoPlist.xcstrings",
                      "Store/MusicStore.swift", "Services/KeychainStore.swift", "Services/SystemPlayback.swift"],
            sources: ["Models/MediaModels.swift", "Store/PlaybackQueue.swift",
                      "Services/JellyfinAPI.swift", "Services/OfflineLibrary.swift", "Services/PlaybackController.swift",
                      "Services/LibrarySearch.swift"],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(name: "TonkunstCoreTests", dependencies: ["TonkunstCore"], path: "Tests/CoreTests")
    ]
)
