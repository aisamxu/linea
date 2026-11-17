// swift-tools-version:5.9
import PackageDescription

/// LineaTextUI 负责自建布局与渲染：CoreText 视口布局、直接绘制、
/// 选区/光标几何和行号 ruler。只依赖 AppKit/CoreText 与 LineaCore。
let package = Package(
    name: "LineaTextUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LineaTextUI", targets: ["LineaTextUI"])
    ],
    dependencies: [
        .package(path: "../LineaCore")
    ],
    targets: [
        .target(
            name: "LineaTextUI",
            dependencies: ["LineaCore"],
            path: "Sources/LineaTextUI"
        ),
        .testTarget(
            name: "LineaTextUITests",
            dependencies: ["LineaTextUI", "LineaCore"],
            path: "Tests/LineaTextUITests"
        )
    ]
)
