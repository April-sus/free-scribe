import SwiftUI

/// The app owns the microphone, because iOS lets nothing else have it: an app
/// extension cannot record through AVAudioEngine, AVAudioRecorder or
/// AVCaptureSession — all three were tried on a real phone and all three refused.
///
/// So the app holds the microphone open, in the background when you leave it, and
/// the keyboard tells it when to start and stop.
@main
struct FreeScribeApp: App {
    var body: some Scene {
        WindowGroup { MainView() }
    }
}
