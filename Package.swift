// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RoboDust",
    // macOS 14 deployment keeps CGWindowListCreateImage callable; it is how the wallpaper
    // gets captured without asking for Screen Recording.
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")],
    targets: [.executableTarget(name: "RoboDust", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "Sources/RoboDust")]
)
