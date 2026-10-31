// swift-tools-version:5.9
// Copyright (C) 2026 Antonio Marogna — EVRApps
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "ReadbackCheck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ReadbackCheck", path: "Sources/ReadbackCheck"),
    ]
)
