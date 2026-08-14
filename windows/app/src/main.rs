// No console window behind the app in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod audio;
mod paste;
mod settings;
mod transcribe;

use audio::AudioHandle;
use free_scribe_core::cleanup::{self, DictationStyle};
use free_scribe_core::model::{self, MachineInfo};
use free_scribe_core::stats::Stats;
use serde::Serialize;
use settings::Settings;
use std::sync::{Arc, Mutex};
use tauri::{Emitter, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use transcribe::Transcriber;

/// Mirrors `AppState.Phase` on macOS.
#[derive(Clone, Serialize, PartialEq)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum Phase {
    Idle,
    Downloading(f64),
    Loading,
    Recording,
    Transcribing,
    Error(String),
}

pub struct App {
    phase: Phase,
    settings: Settings,
    stats: Stats,
    transcriber: Transcriber,
    last_transcript: String,
    /// Bumped whenever a dictation starts or is abandoned, so a transcription that
    /// finishes late can tell it has been superseded and leave the state alone.
    generation: u64,
}

pub type Shared = Arc<Mutex<App>>;

impl App {
    fn new() -> App {
        let settings = Settings::load();
        App {
            phase: Phase::Idle,
            stats: Stats::load(),
            transcriber: Transcriber::new(),
            last_transcript: String::new(),
            generation: 0,
            settings,
        }
    }

    fn active_model(&self) -> String {
        if self.settings.model.is_empty() {
            model::recommended(&MachineInfo::probe()).to_string()
        } else {
            self.settings.model.clone()
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    phase: Phase,
    settings: Settings,
    stats: Stats,
    last_transcript: String,
    machine: String,
    active_model: String,
    active_model_label: String,
    active_model_size: String,
    needs_setup: bool,
    downloaded: Vec<String>,
    level: f32,
}

fn snapshot(shared: &Shared, audio: &AudioHandle) -> Snapshot {
    let app = shared.lock().unwrap();
    let active = app.active_model();

    Snapshot {
        phase: app.phase.clone(),
        settings: app.settings.clone(),
        stats: app.stats.clone(),
        last_transcript: app.last_transcript.clone(),
        machine: MachineInfo::probe().summary(),
        active_model_label: model::label(&active).to_string(),
        active_model_size: model::size(&active).to_string(),
        needs_setup: !Transcriber::is_downloaded(&active),
        downloaded: Transcriber::downloaded_models(),
        active_model: active,
        level: audio.level(),
    }
}

// MARK: Commands

#[tauri::command]
fn get_state(shared: tauri::State<Shared>, audio: tauri::State<AudioHandle>) -> Snapshot {
    snapshot(&shared, &audio)
}

#[tauri::command]
fn list_devices() -> Vec<audio::InputDevice> {
    audio::Recorder::available_inputs()
}

#[tauri::command]
fn styles() -> Vec<serde_json::Value> {
    DictationStyle::ALL
        .iter()
        .map(|style| {
            serde_json::json!({
                "id": serde_json::to_value(style).unwrap(),
                "label": style.label(),
                "detail": style.detail(),
            })
        })
        .collect()
}

#[tauri::command]
fn dictated_marks() -> Vec<String> {
    cleanup::DICTATED_MARKS
        .iter()
        .map(|(spoken, _)| spoken.to_string())
        .collect()
}

#[tauri::command]
fn set_setting(
    key: String,
    value: serde_json::Value,
    shared: tauri::State<Shared>,
) -> Result<(), String> {
    let mut app = shared.lock().unwrap();
    app.settings.set(&key, value)?;
    app.settings.save().map_err(|error| error.to_string())?;

    // Changing the model means the loaded one is no longer the active one.
    if key == "model" {
        app.transcriber.unload();
    }
    Ok(())
}

#[tauri::command]
fn reset_stats(shared: tauri::State<Shared>) {
    Stats::erase();
    shared.lock().unwrap().stats = Stats::default();
}

#[tauri::command]
fn stats_path() -> String {
    Stats::file_path().to_string_lossy().into_owned()
}

#[tauri::command]
fn delete_model(model: String) -> Result<(), String> {
    Transcriber::delete(&model).map_err(|error| error.to_string())
}

/// Streams the GGML weights to disk, reporting progress into `phase` so the window
/// and the tray both reflect it.
#[tauri::command]
fn download_model(handle: tauri::AppHandle, shared: tauri::State<Shared>, model: String) {
    let shared = Arc::clone(&shared);

    std::thread::spawn(move || {
        set_phase(&handle, &shared, Phase::Downloading(0.0));

        let download = || -> Result<(), String> {
            let url = transcribe::download_url(&model);
            let mut response = ureq::get(&url)
                .call()
                .map_err(|error| format!("Could not reach the model host: {error}"))?;

            let total: u64 = response
                .headers()
                .get("content-length")
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse().ok())
                .unwrap_or(0);

            transcribe::ensure_models_directory().map_err(|error| error.to_string())?;
            // Download beside the target and rename at the end, so an interrupted
            // download never looks like a usable model.
            let final_path = Transcriber::model_path(&model);
            let partial_path = final_path.with_extension("partial");
            let mut file = std::fs::File::create(&partial_path)
                .map_err(|error| format!("Could not write the model: {error}"))?;

            let mut reader = response.body_mut().as_reader();
            let mut buffer = vec![0u8; 1 << 16];
            let mut written: u64 = 0;

            loop {
                let read = std::io::Read::read(&mut reader, &mut buffer)
                    .map_err(|error| format!("Download interrupted: {error}"))?;
                if read == 0 {
                    break;
                }
                std::io::Write::write_all(&mut file, &buffer[..read])
                    .map_err(|error| format!("Could not write the model: {error}"))?;

                written += read as u64;
                if total > 0 {
                    let fraction = written as f64 / total as f64;
                    set_phase(&handle, &shared, Phase::Downloading(fraction));
                }
            }

            drop(file);
            std::fs::rename(&partial_path, &final_path)
                .map_err(|error| format!("Could not finish the download: {error}"))
        };

        match download() {
            Ok(()) => set_phase(&handle, &shared, Phase::Idle),
            Err(error) => {
                let _ = std::fs::remove_file(Transcriber::model_path(&model).with_extension("partial"));
                set_phase(&handle, &shared, Phase::Error(error));
            }
        }
    });
}

fn set_phase(handle: &tauri::AppHandle, shared: &Shared, phase: Phase) {
    shared.lock().unwrap().phase = phase.clone();
    let _ = handle.emit("phase", phase);
}

#[tauri::command]
fn start_dictation(
    handle: tauri::AppHandle,
    shared: tauri::State<Shared>,
    audio: tauri::State<AudioHandle>,
) {
    // The recorder is the source of truth for "already going", not the phase, which
    // an error or a late task can leave out of step.
    if audio.is_recording() {
        return;
    }

    {
        let mut app = shared.lock().unwrap();
        // Speaking again while the last one is still working is the user saying
        // "forget that, take this instead", so drop it rather than making them wait.
        if app.phase == Phase::Transcribing {
            app.generation += 1;
        }
        app.generation += 1;
    }

    let device = shared.lock().unwrap().settings.input_device.clone();
    match audio.start(&device) {
        Ok(()) => set_phase(&handle, &shared, Phase::Recording),
        Err(error) => set_phase(&handle, &shared, Phase::Error(error)),
    }
}

#[tauri::command]
fn finish_dictation(
    handle: tauri::AppHandle,
    shared: tauri::State<Shared>,
    audio: tauri::State<AudioHandle>,
) {
    if !audio.is_recording() {
        return;
    }

    let samples = audio.stop();
    if samples.is_empty() {
        set_phase(&handle, &shared, Phase::Idle);
        return;
    }

    set_phase(&handle, &shared, Phase::Transcribing);

    let seconds = samples.len() as f64 / audio::SAMPLE_RATE as f64;
    let shared = Arc::clone(&shared);
    let token = shared.lock().unwrap().generation;

    // Whisper blocks, so it runs off the UI thread.
    std::thread::spawn(move || {
        let (model, language, style, spoken_capitals) = {
            let app = shared.lock().unwrap();
            (
                app.active_model(),
                app.settings.language.clone(),
                app.settings.style,
                app.settings.spoken_capitals,
            )
        };

        let result = {
            let mut app = shared.lock().unwrap();
            app.transcriber
                .load(&model)
                .and_then(|()| {
                    let language = if language.is_empty() {
                        None
                    } else {
                        Some(language.as_str())
                    };
                    app.transcriber.transcribe(&samples, language)
                })
        };

        // A newer dictation superseded this one while it was running.
        if shared.lock().unwrap().generation != token {
            return;
        }

        match result {
            Ok(spoken) => {
                let text = cleanup::apply(&spoken, style, spoken_capitals);
                if text.is_empty() {
                    set_phase(&handle, &shared, Phase::Idle);
                    return;
                }

                {
                    let mut app = shared.lock().unwrap();
                    app.stats.record(&spoken, seconds);
                    let _ = app.stats.save();
                    app.last_transcript = text.clone();
                }

                paste::insert(&text);
                set_phase(&handle, &shared, Phase::Idle);
            }
            Err(error) => {
                shared.lock().unwrap().transcriber.unload();
                set_phase(
                    &handle,
                    &shared,
                    Phase::Error(format!("{error} — press the shortcut to try again")),
                );
            }
        }
    });
}

#[tauri::command]
fn cancel_transcription(handle: tauri::AppHandle, shared: tauri::State<Shared>) {
    shared.lock().unwrap().generation += 1;
    set_phase(&handle, &shared, Phase::Idle);
}

#[tauri::command]
fn copy_last(shared: tauri::State<Shared>) {
    let text = shared.lock().unwrap().last_transcript.clone();
    paste::insert(&text);
}

// MARK: Setup

fn main() {
    let shared: Shared = Arc::new(Mutex::new(App::new()));
    let audio = AudioHandle::spawn();
    let _ = transcribe::ensure_models_directory();

    tauri::Builder::default()
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(Arc::clone(&shared))
        .manage(audio)
        .setup(move |app| {
            let shortcut: Shortcut = shared
                .lock()
                .unwrap()
                .settings
                .shortcut
                .parse()
                .unwrap_or_else(|_| settings::DEFAULT_SHORTCUT.parse().expect("default shortcut"));

            let handle = app.handle().clone();
            app.global_shortcut().on_shortcut(shortcut, move |_, _, event| {
                let shared = handle.state::<Shared>();
                let audio = handle.state::<AudioHandle>();
                // Hold to talk: press starts, release inserts.
                match event.state {
                    ShortcutState::Pressed => start_dictation(handle.clone(), shared, audio),
                    ShortcutState::Released => finish_dictation(handle.clone(), shared, audio),
                }
            })?;

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            list_devices,
            styles,
            dictated_marks,
            set_setting,
            reset_stats,
            stats_path,
            delete_model,
            download_model,
            start_dictation,
            finish_dictation,
            cancel_transcription,
            copy_last,
        ])
        .run(tauri::generate_context!())
        .expect("failed to start Free Scribe");
}
