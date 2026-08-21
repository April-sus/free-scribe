import Foundation
import WhisperKit

/// What we detected about the machine, shown to the user on first launch.
public struct MachineInfo: Sendable {
    public let chip: String
    public let ramGB: Int
    public let cores: Int
    public let appleSilicon: Bool
    /// Free space, which on a phone is often the binding constraint rather than
    /// memory — a 64GB iPhone with photos on it has no room for a 950MB model
    /// however much RAM it has.
    public let freeStorageGB: Int

    public static func probe() -> MachineInfo {
        // Macs name the processor; iOS does not publish that key at all and gives
        // the model identifier instead, so ask for whichever exists here.
        #if os(macOS)
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"
        #else
        let chip = sysctlString("hw.machine") ?? "Unknown device"
        #endif

        return MachineInfo(
            chip: chip.isEmpty ? "Unknown" : chip,
            ramGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            cores: ProcessInfo.processInfo.processorCount,
            appleSilicon: chip.hasPrefix("Apple"),
            freeStorageGB: Self.freeStorageGB()
        )
    }

    /// Reads a sysctl string, or nil when the key does not exist on this platform.
    ///
    /// The size has to be checked: a missing key leaves it at zero, and handing an
    /// empty buffer to `String(cString:)` is a trap rather than an empty string.
    /// That crashed every launch on a real iPhone while the simulator — running on
    /// a Mac, where the key exists — was perfectly happy.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }

        // Trust the reported length rather than assuming a terminator is present.
        let characters = bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let text = String(decoding: characters, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// Space the system says an app may reasonably use, which is not the same as
    /// raw free space — it accounts for what can be purged.
    static func freeStorageGB() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return 0 }
        return Int(bytes / 1_073_741_824)
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

    /// Roughly what each model costs on disk, in gigabytes, for deciding whether
    /// one will fit rather than for display.
    static func sizeGB(of model: String) -> Double {
        switch model {
        case "openai_whisper-tiny.en": 0.08
        case "openai_whisper-base.en": 0.15
        case "openai_whisper-small.en": 0.5
        case "openai_whisper-large-v3-v20240930_626MB": 0.65
        default: 1.0
        }
    }

    /// Leave this much free after installing. A device with no room left behaves
    /// badly in ways that have nothing to do with this app.
    static let storageHeadroomGB = 2.0

    /// Model chosen from hardware limits: memory, and on a phone, space.
    ///
    /// ponytail: RAM and free storage only. If a specific device turns out slower
    /// than its memory suggests, tier on chip generation here instead.
    public static func fallback(for machine: MachineInfo) -> String {
        // Intel Macs have no Neural Engine; CoreML falls back to CPU/GPU and anything
        // above base is painfully slow, so cap it regardless of how much RAM is fitted.
        let byMemory: String
        if !machine.appleSilicon {
            byMemory = "openai_whisper-base.en"
        } else {
            switch machine.ramGB {
            case ..<8: byMemory = "openai_whisper-base.en"
            case ..<16: byMemory = "openai_whisper-small.en"
            default: byMemory = "openai_whisper-large-v3-v20240930_turbo"
            }
        }

        return largestThatFits(upTo: byMemory, freeGB: machine.freeStorageGB)
    }

    /// Steps down from the memory-based choice until one fits the space available.
    /// Reports the smallest model rather than nothing when even that will not fit —
    /// refusing to name a model would leave the user with no way forward.
    static func largestThatFits(upTo ceiling: String, freeGB: Int) -> String {
        let usable = Double(freeGB) - storageHeadroomGB
        // Unknown or unreported free space is not a reason to install the smallest
        // model; that mainly happens on desktops with plenty of room.
        guard freeGB > 0 else { return ceiling }

        let order = catalog.map(\.id)
        guard let ceilingIndex = order.firstIndex(of: ceiling) else { return ceiling }

        for model in order[...ceilingIndex].reversed() where sizeGB(of: model) <= usable {
            return model
        }
        return order.first ?? ceiling
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
