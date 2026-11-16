// swift-tools-version: 6.0
// Paquet DDCKit : couche DDC/CI séparée de l'interface, testable seule.
import PackageDescription

let package = Package(
    name: "DDCKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DDCKit", targets: ["DDCKit"]),
        .executable(name: "ddctool", targets: ["ddctool"]),
    ],
    targets: [
        // Déclarations C des fonctions privées IOAVService (Apple Silicon).
        .target(
            name: "CIOAVService",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "DDCKit",
            dependencies: ["CIOAVService"],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("IOKit")]
        ),
        // Outil en ligne de commande de l'étape 0 : détection, capacités, lecture/écriture.
        .executableTarget(name: "ddctool", dependencies: ["DDCKit"]),
        .testTarget(name: "DDCKitTests", dependencies: ["DDCKit"]),
    ]
)
