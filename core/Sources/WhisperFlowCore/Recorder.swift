// AVAudioPCMBuffer is not Sendable, but the converter's input block runs
// synchronously inside convert(to:error:) — the buffer never escapes.
@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif
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
        private var accepting = true
        private var skipUntil: Date?

        /// Throws away the first moments after the microphone opens.
        func skip(until: Date) {
            lock.lock()
            skipUntil = until
            lock.unlock()
        }
        /// Buffers delivered since the engine started, kept or not. Zero after a
        /// second of recording means the device is not producing audio at all.
        private var delivered = 0

        var deliveredCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return delivered
        }

        func resetDelivered() {
            lock.lock()
            delivered = 0
            lock.unlock()
        }

        func setAccepting(_ accepting: Bool) {
            lock.lock()
            self.accepting = accepting
            lock.unlock()
        }

        var isAccepting: Bool {
            lock.lock()
            defer { lock.unlock() }
            return accepting
        }

        /// Puts back audio taken out before a restart, ahead of anything since.
        func restore(_ earlier: [Float]) {
            guard !earlier.isEmpty else { return }
            lock.lock()
            samples.insert(contentsOf: earlier, at: 0)
            lock.unlock()
        }

        func append(_ new: [Float]) {
            lock.lock()
            delivered += 1
            if let skipUntil, Date() < skipUntil {
                // Still inside the warm-up: counted as delivered, but not kept.
                lock.unlock()
                return
            }
            if accepting { samples.append(contentsOf: new) }
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

    /// Rebuilt rather than reused when the audio devices change underneath it.
    /// After the machine sleeps, the device this was built against is gone: the
    /// engine either refuses to start or delivers silence, and silence is discarded
    /// as nothing said — so dictation looks broken until the app is restarted.
    private var engine = AVAudioEngine()
    /// Set when the system says the devices moved. The engine is replaced at the
    /// start of the next dictation, which is the only safe moment to do it.
    private var engineIsStale = false
    private var configurationObserver: NSObjectProtocol?
    private var converter: AVAudioConverter?
    private let buffer = SampleBuffer()
    /// Whether the engine's input node carries a tap. Only then is it touched to
    /// remove one: creating that node is what binds the system's default microphone.
    private var tapInstalled = false
    #if os(macOS)
    /// Recording from a microphone other than the system default goes through a
    /// capture session instead of the engine.
    ///
    /// An engine binds its input node to the default microphone the moment the node
    /// exists — before a different device can be set on it. When that default is a
    /// pair of AirPods, touching it flips them from music quality into their
    /// call-quality headset mode, however briefly: the first dictation after every
    /// launch, wake, or AirPods reconnection did exactly that, with a USB microphone
    /// chosen the whole time. A capture session opens only the device it is given.
    private var capture: AVCaptureSession?
    private var captureSink: CaptureSink?
    private let captureQueue = DispatchQueue(label: "free-scribe.capture")
    #endif

    public private(set) var isRecording = false
    private var startedAt: Date?
    /// True after a stop that found the engine delivered nothing for the whole
    /// recording: the device was dead, not the room quiet. The engine has already
    /// been rebuilt by then, so the next attempt works — this is for telling the
    /// user why this one did not.
    public private(set) var lastRecordingWasDead = false
    /// What the device handed the converter on the last start, for the log.
    public private(set) var lastInputFormat = ""
    /// 0...1 loudness for the waveform, published per audio buffer.
    public var onLevel: (@MainActor (Float) -> Void)?
    /// CoreAudio UID of the microphone to record from. Empty or unknown means
    /// whatever macOS currently calls the default input.
    public var inputDeviceUID = ""
    /// Called when a route change took the microphone and it could not be reopened,
    /// with whatever had been recorded by then.
    public var onInputLost: (@MainActor ([Float]) -> Void)?

    public init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.devicesChanged() }
        }
    }

    /// The system rebuilt the audio route — AirPods taken out, a headset plugged in,
    /// a call ending. An engine stops itself when that happens and does not start
    /// again. A stream held open for the keyboard went silent, and every dictation
    /// after the AirPods came out was "nothing heard" until the app was reopened.
    ///
    /// So a running engine is rebuilt and restarted at once, on whatever microphone
    /// the route now offers, with what had been said so far kept. If it cannot be
    /// reopened — iOS will not always let a background app open a microphone — the
    /// audio so far goes to `onInputLost`, so it is not thrown away, and the app can
    /// stop claiming to be ready.
    private func devicesChanged() {
        guard isRecording, tapInstalled else {
            engineIsStale = true
            return
        }
        let wasKeeping = buffer.isAccepting
        let kept = buffer.drain()

        stopCapturing()
        isRecording = false
        engine = AVAudioEngine()
        engineIsStale = false

        do {
            try start()
            if wasKeeping {
                buffer.restore(kept)
            } else {
                pause()
            }
            Diagnostics.log("recorder: audio route changed, reopened the microphone (\(lastInputFormat))")
        } catch {
            engineIsStale = true
            Diagnostics.log("recorder: audio route changed and the microphone could not be reopened — \(error)")
            onInputLost?(wasKeeping ? kept : [])
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Throws away the engine and builds a fresh one.
    ///
    /// Safe at any time: a dictation in progress is abandoned rather than corrupted,
    /// which is the right trade when the device it was recording from has gone.
    public func reset() {
        stopCapturing()
        isRecording = false
        buffer.setAccepting(true)
        buffer.drain()
        engine = AVAudioEngine()
        engineIsStale = false
    }

    /// Microphones the system can currently see, for the Settings picker.
    ///
    /// iOS routes audio itself and offers no equivalent choice, so the list is
    /// empty there and the system route is used.
    public static func availableInputs() -> [InputDevice] {
        #if os(iOS)
        return []
        #else
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
        #endif
    }

    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func start() throws {
        guard !isRecording else { return }
        // The devices moved while we were not using them — after a sleep, or a
        // microphone being unplugged. Start from a fresh engine.
        if engineIsStale { reset() }
        buffer.setAccepting(true)
        buffer.drain()

        #if os(macOS)
        // A chosen microphone that is not the system default is opened directly,
        // before anything touches the engine. See `capture`.
        if let device = Self.directDevice(uid: inputDeviceUID) {
            try startCapture(from: device)
            return
        }
        #endif

        // A previous attempt that threw after installing the tap would leave it in
        // place, and installing a second tap on the same bus traps.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        #if os(iOS)
        // Without this the engine throws 'what' (2003329396), which reads as a
        // hardware fault and is really a missing permission. A keyboard extension
        // cannot raise the prompt itself, so the app has to have asked first.
        guard Self.microphoneAuthorized else { throw RecorderError.microphoneDenied }

        // Nothing reaches the engine until the session is in a recording category.
        // In a keyboard extension this only succeeds with Allow Full Access on.
        let session = AVAudioSession.sharedInstance()
        do {
            // A2DP, not `.allowBluetooth`. The latter makes a headset's microphone
            // eligible, and activating with AirPods connected routed input to them —
            // flipping them into call-quality mode for the first dictation, until the
            // built-in microphone was preferred afterwards. A2DP keeps them on music
            // quality for playback and never offers their microphone at all.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true)

            // Bluetooth stays allowed, but the phone's own microphone is preferred
            // over it. Otherwise a paired headset — in a bag, on a desk — becomes the
            // input, and every dictation comes back as nothing heard.
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
        } catch {
            // Separated from the engine's own failure: the two read identically to a
            // user and need completely different fixes.
            throw RecorderError.sessionUnavailable(error)
        }
        #endif

        let input = engine.inputNode
        #if os(macOS)
        // Must happen before the format is read: changing the device changes it.
        // A device that has since been unplugged just leaves us on the default.
        //
        // Left to the system default, a connected Bluetooth headset with a
        // microphone often becomes it — and opening its mic forces the Bluetooth
        // link into the low-quality voice profile, degrading whatever else is
        // playing through it too. Prefer the built-in mic unless the user picked
        // something else in Settings.
        let uid = inputDeviceUID.isEmpty
            ? AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified)?.uniqueID ?? ""
            : inputDeviceUID
        Self.selectDevice(uid: uid, on: input)
        #endif

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RecorderError.noInputDevice
        }
        lastInputFormat = "\(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch, \(inputFormat.commonFormat.rawValue), interleaved \(inputFormat.isInterleaved)"
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
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            self.converter = nil
            // An engine that will not start is usually one holding a device that
            // has gone — after a sleep, most often. A fresh one generally will.
            guard !retrying else { throw error }
            reset()
            retrying = true
            defer { retrying = false }
            try start()
            return
        }
        buffer.resetDelivered()
        buffer.skip(until: Date().addingTimeInterval(Self.warmUpSeconds))
        startedAt = Date()
        lastRecordingWasDead = false
        isRecording = true
    }

    private var retrying = false

    /// Stops whichever is running. The engine's input node is touched only if a tap
    /// was ever put on it.
    private func stopCapturing() {
        #if os(macOS)
        capture?.stopRunning()
        capture = nil
        captureSink = nil
        #endif
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        converter = nil
    }

    #if os(macOS)
    /// The microphone to open directly, when one other than the system default is
    /// chosen. Nil means the engine, which records from the default.
    private static func directDevice(uid: String) -> AVCaptureDevice? {
        guard !uid.isEmpty,
              uid != AVCaptureDevice.default(for: .audio)?.uniqueID
        else { return nil }
        return AVCaptureDevice(uniqueID: uid)
    }

    private func startCapture(from device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // Converted by the output itself into what Whisper wants: 16 kHz mono float.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RecorderError.unsupportedFormat
        }
        session.addInput(input)
        session.addOutput(output)

        let sink = CaptureSink(buffer: buffer) { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        output.setSampleBufferDelegate(sink, queue: captureQueue)

        buffer.resetDelivered()
        buffer.skip(until: Date().addingTimeInterval(Self.warmUpSeconds))
        session.startRunning()
        guard session.isRunning else { throw RecorderError.noInputDevice }

        capture = session
        captureSink = sink
        lastInputFormat = "capture from \(device.localizedName)"
        startedAt = Date()
        lastRecordingWasDead = false
        isRecording = true
    }

    /// Takes capture buffers on the capture queue and puts them in the same sample
    /// buffer the engine writes to, so everything downstream is shared.
    private final class CaptureSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let buffer: SampleBuffer
        private let onLevel: @Sendable (Float) -> Void

        init(buffer: SampleBuffer, onLevel: @escaping @Sendable (Float) -> Void) {
            self.buffer = buffer
            self.onLevel = onLevel
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { return }

            let count = length / MemoryLayout<Float>.size
            let samples = pointer.withMemoryRebound(to: Float.self, capacity: count) {
                Array(UnsafeBufferPointer(start: $0, count: count))
            }
            buffer.append(samples)
            onLevel(Recorder.rms(samples))
        }
    }
    #endif

    /// Keeps the engine running but stops keeping what it hears.
    ///
    /// This is why the app holds the microphone open the whole time it is on duty:
    /// iOS refuses to *start* audio input from the background — `kAUStartIO` fails
    /// with 'what' (2003329396) — so a stream that will be needed later has to be
    /// opened in the foreground and left running. Ignoring it is the only "off"
    /// available.
    public func pause() {
        buffer.setAccepting(false)
        buffer.drain()
    }

    /// Begins keeping audio again, discarding whatever silence preceded it.
    public func beginSegment() {
        buffer.drain()
        buffer.skip(until: Date().addingTimeInterval(Self.warmUpSeconds))
        buffer.setAccepting(true)
    }

    /// The first fraction of a recording is thrown away.
    ///
    /// The microphone opens while the "started" cue is still coming out of the
    /// speaker, and the recogniser hears it: a short dictation came back as
    /// "(beeping)" rather than words, and a bracketed non-speech tag is stripped to
    /// nothing — which reached the user as "nothing could be made out".
    static let warmUpSeconds: TimeInterval = 0.25

    /// The segment just spoken. Empty if it was too short to be speech.
    public func endSegment() -> [Float] {
        buffer.setAccepting(false)
        let captured = buffer.drain()
        guard Double(captured.count) / Self.sampleRate >= Self.minimumSeconds else { return [] }
        return captured
    }

    /// Stops capture and returns the recording. Empty if it was too short to be speech.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        // Recorded for a second or more and never got a single buffer: the engine
        // started but its device is dead. Rebuild now, so the next press works,
        // and say so, so this one is not mistaken for the user being silent.
        let held = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        if held >= 1, buffer.deliveredCount == 0 {
            lastRecordingWasDead = true
            reset()
            return []
        }

        stopCapturing()

        #if os(iOS)
        // Handing the route back matters: whatever the user was playing before they
        // dictated should carry on afterwards.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        let captured = buffer.drain()
        guard Double(captured.count) / Self.sampleRate >= Self.minimumSeconds else { return [] }
        return captured
    }

    #if os(macOS)
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
    #endif

    nonisolated private static func convert(
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

    nonisolated private static func rms(_ samples: [Float]) -> Float {
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
    case sessionUnavailable(Error)
    case deadDevice

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone was found."
        case .unsupportedFormat: "This microphone's audio format is not supported."
        case .microphoneDenied: "Free Scribe has no microphone permission yet. Open the app and allow it."
        case .deadDevice: "The microphone produced nothing — it has been reset, try again."
        case .sessionUnavailable(let underlying):
            "The audio session would not start: \((underlying as NSError).code)"
        }
    }
}
