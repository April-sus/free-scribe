//! Microphone capture, resampled to the 16 kHz mono f32 Whisper expects.
//! Push-to-talk only: buffer everything, hand it over on stop.
//!
//! The macOS equivalent is `Recorder.swift`. Same shape, WASAPI underneath instead
//! of AVAudioEngine.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, SampleFormat, Stream};
use std::sync::{Arc, Mutex};

pub const SAMPLE_RATE: u32 = 16_000;
/// Below this we assume the user did not actually say anything.
pub const MINIMUM_SECONDS: f32 = 0.3;

#[derive(Clone, serde::Serialize)]
pub struct InputDevice {
    pub id: String,
    pub name: String,
}

/// Shared with the audio thread, so it is a plain mutex rather than app state.
#[derive(Default)]
struct Buffer {
    samples: Vec<f32>,
    level: f32,
}

pub struct Recorder {
    buffer: Arc<Mutex<Buffer>>,
    /// `cpal::Stream` is not `Send`, so the whole recorder stays on one thread and
    /// the stream is simply dropped to stop capture.
    stream: Option<Stream>,
}

impl Default for Recorder {
    fn default() -> Self {
        Self::new()
    }
}

impl Recorder {
    pub fn new() -> Self {
        Recorder {
            buffer: Arc::new(Mutex::new(Buffer::default())),
            stream: None,
        }
    }

    pub fn is_recording(&self) -> bool {
        self.stream.is_some()
    }

    pub fn available_inputs() -> Vec<InputDevice> {
        let host = cpal::default_host();
        host.input_devices()
            .map(|devices| {
                devices
                    .filter_map(|device| {
                        let name = device.description().ok()?.name().to_string();
                        Some(InputDevice {
                            id: name.clone(),
                            name,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// `device_id` is the device name, empty for the system default.
    pub fn start(&mut self, device_id: &str) -> Result<(), String> {
        if self.is_recording() {
            return Ok(());
        }

        let device = Self::device(device_id).ok_or("No microphone was found.")?;
        let config = device
            .default_input_config()
            .map_err(|error| format!("This microphone's format is not supported: {error}"))?;

        let channels = config.channels() as usize;
        let source_rate = config.sample_rate();
        let format = config.sample_format();
        let buffer = Arc::clone(&self.buffer);

        {
            let mut guard = buffer.lock().unwrap();
            guard.samples.clear();
            guard.level = 0.0;
        }

        let on_error = |error| eprintln!("audio stream error: {error}");
        let stream_config: cpal::StreamConfig = config.into();

        // Samples are appended straight from the audio thread. The macOS build
        // learned this the hard way: hopping to the UI thread first loses whatever
        // arrives in the last moments before stop, clipping the end of every take.
        let stream = match format {
            SampleFormat::F32 => device.build_input_stream(
                stream_config.clone(),
                move |data: &[f32], _: &_| append(&buffer, data, channels, source_rate),
                on_error,
                None,
            ),
            SampleFormat::I16 => device.build_input_stream(
                stream_config.clone(),
                move |data: &[i16], _: &_| {
                    let floats: Vec<f32> = data.iter().map(|v| *v as f32 / 32768.0).collect();
                    append(&buffer, &floats, channels, source_rate)
                },
                on_error,
                None,
            ),
            SampleFormat::U16 => device.build_input_stream(
                stream_config.clone(),
                move |data: &[u16], _: &_| {
                    let floats: Vec<f32> = data
                        .iter()
                        .map(|v| (*v as f32 - 32768.0) / 32768.0)
                        .collect();
                    append(&buffer, &floats, channels, source_rate)
                },
                on_error,
                None,
            ),
            other => return Err(format!("Unsupported sample format {other:?}")),
        }
        .map_err(|error| format!("Could not open the microphone: {error}"))?;

        stream
            .play()
            .map_err(|error| format!("Could not start the microphone: {error}"))?;
        self.stream = Some(stream);
        Ok(())
    }

    /// Stops capture and returns the recording. Empty if it was too short to be speech.
    pub fn stop(&mut self) -> Vec<f32> {
        if self.stream.take().is_none() {
            return Vec::new();
        }

        let mut guard = self.buffer.lock().unwrap();
        let captured = std::mem::take(&mut guard.samples);
        guard.level = 0.0;

        if captured.len() as f32 / SAMPLE_RATE as f32 >= MINIMUM_SECONDS {
            captured
        } else {
            Vec::new()
        }
    }

    /// 0...1 loudness for the waveform.
    pub fn level(&self) -> f32 {
        self.buffer.lock().unwrap().level
    }

    fn device(device_id: &str) -> Option<Device> {
        let host = cpal::default_host();
        if device_id.is_empty() {
            return host.default_input_device();
        }

        host.input_devices()
            .ok()?
            .find(|device| device.description().is_ok_and(|info| info.name() == device_id))
            // A device that has since been unplugged just leaves us on the default.
            .or_else(|| host.default_input_device())
    }
}

// MARK: Thread handle

/// `cpal::Stream` is `!Send`, so the recorder cannot sit in Tauri's shared state.
/// It lives on its own thread instead and is driven by messages.
enum Command {
    Start(String, std::sync::mpsc::Sender<Result<(), String>>),
    Stop(std::sync::mpsc::Sender<Vec<f32>>),
    Level(std::sync::mpsc::Sender<f32>),
    IsRecording(std::sync::mpsc::Sender<bool>),
}

#[derive(Clone)]
pub struct AudioHandle {
    sender: std::sync::mpsc::Sender<Command>,
}

impl AudioHandle {
    pub fn spawn() -> AudioHandle {
        let (sender, receiver) = std::sync::mpsc::channel::<Command>();

        std::thread::spawn(move || {
            let mut recorder = Recorder::new();
            while let Ok(command) = receiver.recv() {
                match command {
                    Command::Start(device, reply) => {
                        let _ = reply.send(recorder.start(&device));
                    }
                    Command::Stop(reply) => {
                        let _ = reply.send(recorder.stop());
                    }
                    Command::Level(reply) => {
                        let _ = reply.send(recorder.level());
                    }
                    Command::IsRecording(reply) => {
                        let _ = reply.send(recorder.is_recording());
                    }
                }
            }
        });

        AudioHandle { sender }
    }

    fn ask<T>(&self, make: impl FnOnce(std::sync::mpsc::Sender<T>) -> Command, fallback: T) -> T {
        let (reply, answer) = std::sync::mpsc::channel();
        if self.sender.send(make(reply)).is_err() {
            return fallback;
        }
        answer.recv().unwrap_or(fallback)
    }

    pub fn start(&self, device_id: &str) -> Result<(), String> {
        let device = device_id.to_string();
        self.ask(
            |reply| Command::Start(device, reply),
            Err("The audio thread stopped.".to_string()),
        )
    }

    pub fn stop(&self) -> Vec<f32> {
        self.ask(Command::Stop, Vec::new())
    }

    pub fn level(&self) -> f32 {
        self.ask(Command::Level, 0.0)
    }

    pub fn is_recording(&self) -> bool {
        self.ask(Command::IsRecording, false)
    }
}

fn append(buffer: &Arc<Mutex<Buffer>>, data: &[f32], channels: usize, source_rate: u32) {
    let mono = to_mono(data, channels);
    let resampled = resample(&mono, source_rate, SAMPLE_RATE);
    let level = rms(&resampled);

    let mut guard = buffer.lock().unwrap();
    guard.samples.extend_from_slice(&resampled);
    guard.level = level;
}

fn to_mono(data: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return data.to_vec();
    }
    data.chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect()
}

/// Box-filter decimation: average the source samples falling inside each output
/// sample's window.
///
/// ponytail: no anti-aliasing beyond the averaging. Whisper tolerates it, and
/// 48k→16k is an exact 3:1 so the common case is a clean 3-sample mean. Swap in
/// `rubato` if transcription quality ever looks rate-dependent.
fn resample(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || input.is_empty() {
        return input.to_vec();
    }

    let ratio = from as f64 / to as f64;
    let out_len = (input.len() as f64 / ratio).floor() as usize;
    let mut out = Vec::with_capacity(out_len);

    for index in 0..out_len {
        let start = (index as f64 * ratio) as usize;
        let end = (((index + 1) as f64 * ratio) as usize).min(input.len()).max(start + 1);
        let window = &input[start..end];
        out.push(window.iter().sum::<f32>() / window.len() as f32);
    }

    out
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let mean = samples.iter().map(|value| value * value).sum::<f32>() / samples.len() as f32;
    // Map roughly -50 dB...0 dB onto 0...1 so quiet speech still moves the bars.
    let db = 20.0 * mean.sqrt().max(1e-7).log10();
    ((db + 50.0) / 50.0).clamp(0.0, 1.0)
}
