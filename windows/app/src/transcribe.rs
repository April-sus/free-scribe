//! Whisper through whisper.cpp. The macOS equivalent is `Transcriber.swift`, which
//! uses CoreML via WhisperKit — the model files are not interchangeable, which is
//! why `free_scribe_core::model` lists GGML names.

use std::path::{Path, PathBuf};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub struct Transcriber {
    context: Option<WhisperContext>,
    loaded_model: Option<String>,
}

impl Default for Transcriber {
    fn default() -> Self {
        Self::new()
    }
}

impl Transcriber {
    pub fn new() -> Self {
        Transcriber {
            context: None,
            loaded_model: None,
        }
    }

    pub fn loaded_model(&self) -> Option<&str> {
        self.loaded_model.as_deref()
    }

    /// Models live outside the install directory so an update never throws away a
    /// download the user waited for.
    pub fn models_directory() -> PathBuf {
        free_scribe_core::data_directory().join("models")
    }

    pub fn model_path(model: &str) -> PathBuf {
        Self::models_directory().join(format!("{model}.bin"))
    }

    pub fn is_downloaded(model: &str) -> bool {
        Self::model_path(model).is_file()
    }

    pub fn downloaded_models() -> Vec<String> {
        let Ok(entries) = std::fs::read_dir(Self::models_directory()) else {
            return Vec::new();
        };

        let mut models: Vec<String> = entries
            .filter_map(|entry| {
                let path = entry.ok()?.path();
                if path.extension()? != "bin" {
                    return None;
                }
                Some(path.file_stem()?.to_string_lossy().into_owned())
            })
            .collect();
        models.sort();
        models
    }

    pub fn delete(model: &str) -> std::io::Result<()> {
        std::fs::remove_file(Self::model_path(model))
    }

    /// Loads the model and keeps it warm between dictations — reloading per
    /// utterance would dominate the latency.
    pub fn load(&mut self, model: &str) -> Result<(), String> {
        if self.loaded_model.as_deref() == Some(model) && self.context.is_some() {
            return Ok(());
        }

        let path = Self::model_path(model);
        if !path.is_file() {
            return Err(format!("{model} has not been downloaded yet."));
        }

        let context = WhisperContext::new_with_params(&path, WhisperContextParameters::default())
        .map_err(|error| format!("Could not load {model}: {error}"))?;

        self.context = Some(context);
        self.loaded_model = Some(model.to_string());
        Ok(())
    }

    pub fn unload(&mut self) {
        self.context = None;
        self.loaded_model = None;
    }

    /// `language` is an ISO code such as "en", or None to let Whisper detect it.
    pub fn transcribe(&self, samples: &[f32], language: Option<&str>) -> Result<String, String> {
        let context = self
            .context
            .as_ref()
            .ok_or("No speech model is loaded yet.")?;

        let mut state = context
            .create_state()
            .map_err(|error| format!("Could not start transcription: {error}"))?;

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(language);
        params.set_translate(false);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);

        state
            .full(params, samples)
            .map_err(|error| format!("Transcription failed: {error}"))?;

        // full_n_segments returns a plain count in this version, not a Result.
        let mut text = String::new();
        for index in 0..state.full_n_segments() {
            if let Some(segment) = state.get_segment(index) {
                if let Ok(chunk) = segment.to_str_lossy() {
                    text.push_str(&chunk);
                }
            }
        }

        Ok(clean(&text))
    }
}

/// Whisper emits leading spaces and, on silence, bracketed non-speech tags like
/// "(wind blowing)" or "[BLANK_AUDIO]" that must not be pasted.
fn clean(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut depth = 0usize;

    for character in text.chars() {
        match character {
            '(' | '[' => depth += 1,
            ')' | ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(character),
            _ => {}
        }
    }

    out.trim().to_string()
}

/// Where the GGML weights come from. Same project as the CoreML builds the macOS
/// app uses, different format.
pub fn download_url(model: &str) -> String {
    format!("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{model}.bin")
}

pub fn ensure_models_directory() -> std::io::Result<&'static Path> {
    let directory = Transcriber::models_directory();
    std::fs::create_dir_all(&directory)?;
    Ok(Box::leak(directory.into_boxed_path()))
}

#[cfg(test)]
mod tests {
    use super::clean;

    #[test]
    fn non_speech_tags_are_stripped() {
        assert_eq!(clean(" hello there "), "hello there");
        assert_eq!(clean("[BLANK_AUDIO]"), "");
        assert_eq!(clean(" (wind blowing) send it "), "send it");
    }
}
