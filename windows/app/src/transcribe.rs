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

        // Whisper hallucinates confidently on silence — a muted microphone reliably
        // produces "you". Pasting a word the user never said is the worst thing this
        // app can do, and in scribe mode it would be a breach of the rules.
        if peak(samples) < SILENCE_THRESHOLD {
            return Ok(String::new());
        }

        let padded = pad(samples);
        let samples = padded.as_slice();

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
        // The energy gate catches silence; these catch loud non-speech, where
        // Whisper will otherwise invent a confident short sentence.
        params.set_no_speech_thold(0.6);
        params.set_logprob_thold(-1.0);
        params.set_entropy_thold(2.4);

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

/// Below this, treat the recording as nothing said. Measured against real clips:
/// silence and room tone peak at 0.002 or less, speech at 0.19 or more, so this sits
/// with two orders of magnitude of margin either side. Matches the macOS build.
pub const SILENCE_THRESHOLD: f32 = 0.01;

/// Whisper works on a long window and returns nothing at all for very short clips —
/// "Yes." on its own transcribes as empty until it is padded.
const MINIMUM_SAMPLES: usize = 32_000; // 2s at 16 kHz

/// Loudest 100 ms of the recording. Peak rather than mean, so a short word surrounded
/// by silence still registers.
pub fn peak(samples: &[f32]) -> f32 {
    samples
        .chunks(1600)
        .map(|chunk| {
            let mean = chunk.iter().map(|v| v * v).sum::<f32>() / chunk.len() as f32;
            mean.sqrt()
        })
        .fold(0.0, f32::max)
}

pub fn pad(samples: &[f32]) -> Vec<f32> {
    let mut out = samples.to_vec();
    out.resize(out.len().max(MINIMUM_SAMPLES), 0.0);
    out
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
    use super::{clean, pad, peak, SILENCE_THRESHOLD};

    #[test]
    fn silence_is_below_the_threshold_and_speech_is_above() {
        let silence = vec![0.0f32; 32000];
        let room_tone: Vec<f32> = (0..32000).map(|i| (i as f32 * 0.7).sin() * 0.002).collect();
        let speech: Vec<f32> = (0..32000).map(|i| (i as f32 * 0.05).sin() * 0.2).collect();

        assert!(peak(&silence) < SILENCE_THRESHOLD);
        assert!(peak(&room_tone) < SILENCE_THRESHOLD);
        assert!(peak(&speech) > SILENCE_THRESHOLD);
    }

    #[test]
    fn short_recordings_are_padded_for_whisper() {
        assert_eq!(pad(&vec![0.2f32; 8000]).len(), 32000);
        assert_eq!(pad(&vec![0.2f32; 48000]).len(), 48000);
    }

    #[test]
    fn padding_keeps_the_spoken_audio_at_the_front() {
        let result = pad(&[0.5, 0.4, 0.3]);
        assert_eq!(&result[..3], &[0.5, 0.4, 0.3]);
        assert_eq!(result[result.len() - 1], 0.0);
    }

    #[test]
    fn non_speech_tags_are_stripped() {
        assert_eq!(clean(" hello there "), "hello there");
        assert_eq!(clean("[BLANK_AUDIO]"), "");
        assert_eq!(clean(" (wind blowing) send it "), "send it");
    }
}
