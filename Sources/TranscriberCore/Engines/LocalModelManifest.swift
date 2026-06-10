import Foundation

public struct LocalModelManifest: Sendable, Equatable {
    public let modelID: String
    let artifacts: [LocalModelArtifact]
    let requiredFreeBytes: Int64

    public init(modelID: String, artifacts: [LocalModelArtifact], requiredFreeBytes: Int64? = nil) {
        self.modelID = modelID
        self.artifacts = artifacts.sorted { $0.relativePath < $1.relativePath }
        let artifactBytes = artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
        // Keep enough room for the final file plus the in-flight .partial and
        // a small filesystem overhead buffer.
        self.requiredFreeBytes = requiredFreeBytes ?? (artifactBytes * 2 + 512 * 1024 * 1024)
    }

    /// Every manifest this app is allowed to download. The downloader and
    /// manager refuse any modelID outside this set, so a compromised
    /// settings blob can't redirect downloads to an arbitrary repo.
    static var allPinned: [LocalModelManifest] {
        [cohereTranscribePinned, sileroVADPinned, ecapaLanguageIDPinned]
    }

    static func pinned(modelID: String) -> LocalModelManifest? {
        allPinned.first { $0.modelID == modelID }
    }

    public static let cohereTranscribePinned = LocalModelManifest(
        modelID: CohereMLXBackend.modelID,
        artifacts: [
            LocalModelArtifact(
                relativePath: "config.json",
                byteCount: 3_998,
                sha256Hex: "5de7e586cec6d8f51225c8d5fe17a56a3043dda9af8c42f9cb01dd545905eb18"
            ),
            LocalModelArtifact(
                relativePath: "conversion_summary.json",
                byteCount: 5_237,
                sha256Hex: "f3f763b9ff233b194df209277ab670d7768745f92eab0efb52b769991743b159"
            ),
            LocalModelArtifact(
                relativePath: "key_map.json",
                byteCount: 179_652,
                sha256Hex: "42cf585ab25335db650b353abcaa9d219d51a04ef04eae5869de6122e85a7be8"
            ),
            LocalModelArtifact(
                relativePath: "model.safetensors",
                byteCount: 4_131_827_448,
                sha256Hex: "1ec6ba9ee27da02b21b3ffdb5183b77020351d3331d05a74ad8d58a09394a2b8"
            ),
            LocalModelArtifact(
                relativePath: "preprocessor_config.json",
                byteCount: 420,
                sha256Hex: "9f297d330646ecc8ebb9dc5784f48b7c35b118c913e306a1ccd0192f2c976332"
            ),
            LocalModelArtifact(
                relativePath: "special_tokens_map.json",
                byteCount: 4_091,
                sha256Hex: "1814ce01458ff6a72b04a6618e75f18ce627be4dc17619cd3a7cd7f71e137f0f"
            ),
            LocalModelArtifact(
                relativePath: "tokenizer.model",
                byteCount: 492_827,
                sha256Hex: "6d21e6a83b2d0d3e1241a7817e4bef8eb63bcb7cfe4a2675af9a35ff3bbf0e14"
            ),
            LocalModelArtifact(
                relativePath: "tokenizer_config.json",
                byteCount: 48_141,
                sha256Hex: "0dfeb3eeba07bccaa1b4bf78f3135ad3059acf8d18f681675832b285ac0035b0"
            )
        ]
    )

    /// Silero VAD weights for wrapper-side speech gating in the local
    /// engine (silent stretches are never sent to the Cohere model).
    /// Loaded via `SileroVAD.fromModelDirectory(_:)`.
    public static let sileroVADPinned = LocalModelManifest(
        modelID: "mlx-community/silero-vad",
        artifacts: [
            LocalModelArtifact(
                relativePath: "config.json",
                byteCount: 549,
                sha256Hex: "f411ebae77d635372a636645fca4a4bb574b2da73e49b21bfef9685ae90e31bc"
            ),
            LocalModelArtifact(
                relativePath: "model.safetensors",
                byteCount: 2_179_454,
                sha256Hex: "185e0bc3ee2c48ce425a37209fe917a1aca22ab6b85799430dd1b4894087a8b8"
            )
        ],
        // Tiny model: skip the (artifacts*2 + 512MB) default headroom rule
        // so a nearly-full disk doesn't block a 2 MB download.
        requiredFreeBytes: 64 * 1024 * 1024
    )

    /// ECAPA-TDNN VoxLingua107 language-identification weights for the
    /// auto-detect pre-pass. Loaded via `EcapaTdnn.fromModelDirectory(_:)`.
    public static let ecapaLanguageIDPinned = LocalModelManifest(
        modelID: "beshkenadze/lang-id-voxlingua107-ecapa-mlx",
        artifacts: [
            LocalModelArtifact(
                relativePath: "config.json",
                byteCount: 3_024,
                sha256Hex: "ca968b86e19541847dc7b1e7ca53e2aa5084818edf7def82ac9e407e596fb71f"
            ),
            LocalModelArtifact(
                relativePath: "ecapa_tdnn_lid107.safetensors",
                byteCount: 85_172_012,
                sha256Hex: "bae5627c78e942e6ca15af87cbfd582915ead6ae2d8f839ad225504c946ddbc8"
            )
        ]
    )
}
