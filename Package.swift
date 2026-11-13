// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
    name: "TokenMoon",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TokenMoonCore", targets: ["TokenMoonCore"]),
        .executable(name: "TokenMoon", targets: ["TokenMoonApp"]),
        .executable(name: "TokenMoonLoginItem", targets: ["TokenMoonLoginItem"])
    ],
    targets: [
        .target(name: "TokenMoonCore", resources: [.process("Resources")]),
        .executableTarget(name: "TokenMoonApp", dependencies: ["TokenMoonCore"]),
        .executableTarget(name: "TokenMoonLoginItem"),
        .testTarget(name: "TokenMoonCoreTests", dependencies: ["TokenMoonCore"])
    ]
)
