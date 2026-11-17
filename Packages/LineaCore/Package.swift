// swift-tools-version:5.9
import PackageDescription

/// LineaCore 只依赖 Foundation，负责文本缓冲、行索引、选区、事务与撤销。
/// 不引入 AppKit/CoreText，保证未来可以替换布局/渲染层而不动文本内核。
let package = Package(
    name: "LineaCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LineaCore", targets: ["LineaCore"])
    ],
    targets: [
        .target(
            name: "LineaCore",
            path: "Sources/LineaCore"
        ),
        .testTarget(
            name: "LineaCoreTests",
            dependencies: ["LineaCore"],
            path: "Tests/LineaCoreTests"
        )
    ]
)
