// AVAudioPCMBuffer is not Sendable, but the converter's input block runs
// synchronously inside convert(to:error:) — the buffer never escapes.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// A microphone the user can pick in Settings. `id` is the CoreAudio device UID,
/// which survives reboots and reconnections, unlike the numeric device ID.
public struct InputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

/// Microphone capture, resampled to the 16 kHz mono Float32 that Whisper expects.
/// Push-to-talk only: buffer everything, hand it over on stop.
@MainActor
public final class Recorder {
    public static let sampleRate: Double = 16000
    /// Below this we assume the user did not actually say anything.
    public static let minimumSeconds: Double = 0.3

    /// Written from the real-time audio thread, drained from the main actor.
    private final class SampleBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []

        func append(_ new: [Float]) {
            lock.lock()
            samples.append(contentsOf: new)
            lock.unlock()
        }

        @discardableResult
        func drain() -> [Float] {
            lock.lock()
            defer {
                samples.removeAll(keepingCapacity: true)
                lock.unlock()
            }
            return samples
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let buffer = SampleBuffer()

    public private(set) var isRecording = false
    /// 0...1 loudness for the waveform, published per audio buffer.
    public var onLevel: (@MainActor (Float) -> Void)?
    /// CoreAudio UID of the microphone to record from. Empty or unknown means
    /// whatever macOS currently calls the default input.
    public var inputDeviceUID = ""

    public init() {}

    /// Microphones macOS can currently see, for the Settings picker.
    public static func availableInputs() -> [InputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func start() throws {
        guard !isRecording else { return }
        buffer.drain()

        // A previous attempt that threw after installing the tap would leave it in
        // place, and installing a second tap on the same bus traps. Cheap to repeat.
        engine.inputNode.removeTap(onBus: 0)

        let input = engine.inputNode
        // Must happen before the format is read: changing the device changes it.
        // A device that has since been unplugged just leaves us on the default.
        Self.selectDevice(uid: inputDeviceUID, on: input)

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RecorderError.noInputDevice
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.unsupportedFormat
        }
        self.converter = converter

        let sink = buffer
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcm, _ in
            guard let converted = Self.convert(pcm, with: converter, to: target) else { return }
            // Appended on the audio thread, not hopped to the main actor: the hop used
            // to lose whatever arrived in the last moments before stop(), which clipped
            // the end of every dictation.
            sink.append(converted)

            let level = Self.rms(converted)
            Task { @MainActor [weak self] in
                self?.onLevel?(level)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw error
        }
        isRecording = true
    }

    /// Stops capture and returns the recording. Empty if it was too short to be speech.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil

        let captured = buffer.drain()
        guard Double(captured.count) / Self.sampleRate >= Self.minimumSeconds else { return [] }
        return captured
    }

    /// Points AVAudioEngine's input at a specific device. AVAudioEngine has no Swift
    /// API for this — it only ever uses the system default — so it has to be set on
    /// the underlying audio unit.
    private static func selectDevice(uid: String, on input: AVAudioInputNode) {
        guard !uid.isEmpty,
              let unit = input.audioUnit,
              var deviceID = deviceID(forUID: uid)
        else { return }

        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString

        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> [Float]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        // Map roughly -50 dB...0 dB onto 0...1 so quiet speech still moves the bars.
        let db = 20 * log10(max(sqrt(mean), 1e-7))
        return min(max((db + 50) / 50, 0), 1)
    }
}

public enum RecorderError: LocalizedError {
    case noInputDevice
    case unsupportedFormat
    case microphoneDenied

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone was found."
        case .unsupportedFormat: "This microphone's audio format is not supported."
        case .microphoneDenied: "Microphone access was denied in System Settings."
        }
    }
}
