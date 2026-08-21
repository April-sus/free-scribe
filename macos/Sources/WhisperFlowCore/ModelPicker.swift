import Foundation
import WhisperKit

/// What we detected about the machine, shown to the user on first launch.
public struct MachineInfo: Sendable {
    public let chip: String
    public let ramGB: Int
    public let cores: Int
    public let appleSilicon: Bool

    public static func probe() -> MachineInfo {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let chip = String(cString: bytes)

        return MachineInfo(
            chip: chip.isEmpty ? "Unknown CPU" : chip,
            ramGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            cores: ProcessInfo.processInfo.processorCount,
            appleSilicon: chip.hasPrefix("Apple")
        )
    }

    public var summary: String { "\(chip) · \(ramGB) GB RAM · \(cores) cores" }
}

public enum ModelPicker {
    /// Models we offer in Settings, weakest to strongest, with rough download sizes.
    public static let catalog: [(id: String, label: String, size: String)] = [
        ("openai_whisper-tiny.en", "Compact · English", "~75 MB"),
        ("openai_whisper-base.en", "Light · English", "~145 MB"),
        ("openai_whisper-small.en", "Standard · English", "~470 MB"),
        ("openai_whisper-large-v3-v20240930_626MB", "Accurate · compact", "~626 MB"),
        ("openai_whisper-large-v3-v20240930_turbo", "Accurate · all languages", "~950 MB"),
    ]

    public static func label(for id: String) -> String {
        catalog.first { $0.id == id }?.label ?? id
    }

    public static func size(for id: String) -> String {
        catalog.first { $0.id == id }?.size ?? "unknown size"
    }

    /// Model chosen purely from hardware limits. Used when WhisperKit's own device
    /// map has no entry for this machine, and it is the piece the tests pin down.
    ///
    /// ponytail: RAM + Apple-Silicon check only. If a specific Mac turns out to be
    /// slower than its RAM suggests, tier on chip generation here instead.
    public static func fallback(for machine: MachineInfo) -> String {
        // Intel Macs have no Neural Engine; CoreML falls back to CPU/GPU and anything
        // above base is painfully slow, so cap it regardless of how much RAM is fitted.
        guard machine.appleSilicon else { return "openai_whisper-base.en" }

        switch machine.ramGB {
        case ..<8: return "openai_whisper-base.en"
        case ..<16: return "openai_whisper-small.en"
        default: return "openai_whisper-large-v3-v20240930_turbo"
        }
    }

    /// What WhisperKit returns for a machine its device map has never heard of.
    /// That answer ignores how much RAM is actually fitted, so we treat it as
    /// "no opinion" rather than a recommendation.
    static let unknownDeviceDefault = "openai_whisper-base"

    /// The model the app installs on first launch: WhisperKit's device-specific
    /// recommendation when it knows this machine, our hardware tier otherwise.
    public static func automatic(for machine: MachineInfo) -> String {
        let recommended = WhisperKit.recommendedModels().default
        return recommended == unknownDeviceDefault ? fallback(for: machine) : recommended
    }
}
