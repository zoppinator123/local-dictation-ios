// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalDictationIOS",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "LocalDictationCore", targets: ["LocalDictationCore"]),
        .executable(name: "LocalDictationTestRunner", targets: ["LocalDictationTestRunner"]),
    ],
    targets: [
        .target(
            name: "LocalDictationCore",
            path: "Shared"
        ),
        .target(
            name: "LocalDictationTestSupport",
            dependencies: ["LocalDictationCore"],
            path: "Tests",
            exclude: ["TestRunnerMain.swift"],
            sources: [
                "AllTests.swift",
                "CaptureTests.swift",
                "CleanupTests.swift",
                "Harness.swift",
                "KeyboardSessionTests.swift",
                "PipelineTests.swift",
                "ReadinessTests.swift",
                "SharedStoreTests.swift",
                "VocabularyTests.swift",
            ]
        ),
        .executableTarget(
            name: "LocalDictationTestRunner",
            dependencies: ["LocalDictationTestSupport"],
            path: "Tests",
            exclude: [
                "AllTests.swift",
                "CaptureTests.swift",
                "CleanupTests.swift",
                "Harness.swift",
                "KeyboardSessionTests.swift",
                "PipelineTests.swift",
                "ReadinessTests.swift",
                "SharedStoreTests.swift",
                "VocabularyTests.swift",
            ],
            sources: ["TestRunnerMain.swift"]
        ),
    ]
)
