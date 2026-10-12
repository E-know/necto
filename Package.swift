// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Necto",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(name: "NectoSDK", targets: [
            "NectoSDK", "NectoDefaultPlugins", "NectoProcessMetrics",
            "NectoURLSessionCapture", "NectoModel", "NectoTransport",
        ]),
    ],
    targets: [
        .target(name: "NectoModel", path: "SDK/iOS/Sources/NectoModel"),
        .target(
            name: "NectoTransport",
            path: "SDK/iOS/Sources/NectoTransport"
        ),
        .target(
            name: "NectoSDK",
            dependencies: ["NectoModel", "NectoTransport"],
            path: "SDK/iOS/Sources/NectoSDK"
        ),
        .target(
            name: "NectoDefaultPlugins",
            dependencies: [
                "NectoModel", "NectoSDK",
                .target(name: "NectoTouchInjection", condition: .when(platforms: [.iOS])),
            ],
            path: "SDK/iOS/Sources/NectoDefaultPlugins",
            resources: [
                .copy("Panels"),
            ]
        ),
        .target(name: "NectoTouchInjection", path: "SDK/iOS/Sources/NectoTouchInjection"),
        // CPU, memory and frame-rate capture for apps that explicitly opt in.
        .target(
            name: "NectoProcessMetrics",
            dependencies: ["NectoDefaultPlugins", "NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoProcessMetrics"
        ),
        // Capture stays separate from the reporting API and starts only on registration.
        .target(
            name: "NectoURLSessionCapture",
            dependencies: ["NectoDefaultPlugins", "NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoURLSessionCapture"
        ),
        .testTarget(
            name: "NectoModelTests",
            dependencies: ["NectoModel"],
            path: "SDK/iOS/Tests/NectoModelTests"
        ),
        .testTarget(
            name: "NectoTransportTests",
            dependencies: ["NectoTransport"],
            path: "SDK/iOS/Tests/NectoTransportTests"
        ),
        .testTarget(
            name: "NectoSDKTests",
            dependencies: ["NectoSDK", "NectoDefaultPlugins", "NectoProcessMetrics", "NectoTransport", "NectoModel"],
            path: "SDK/iOS/Tests/NectoSDKTests"
        ),
        .testTarget(
            name: "NectoProcessMetricsTests",
            dependencies: ["NectoProcessMetrics", "NectoDefaultPlugins", "NectoSDK", "NectoModel"],
            path: "SDK/iOS/Tests/NectoProcessMetricsTests"
        ),
    ]
)
