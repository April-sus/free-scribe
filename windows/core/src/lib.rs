//! The portable half of Free Scribe: everything that decides what text comes out
//! of a dictation, with no windowing, audio or inference code.
//!
//! It is a deliberate port of the macOS app's `WhisperFlowCore`, not a rewrite.
//! The scribe rules in particular are exam behaviour, so the test suite mirrors
//! the Swift one case for case — if the two platforms ever disagree, a test fails.

pub mod cleanup;
pub mod model;
pub mod stats;

pub use cleanup::{apply, scribed, tidied, DictationStyle};
pub use model::MachineInfo;
pub use stats::Stats;

use std::path::PathBuf;

/// Where models and stats live: `%APPDATA%\FreeScribe` on Windows, and an
/// equivalent per-user directory elsewhere so the tests can run anywhere.
pub fn data_directory() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("XDG_DATA_HOME").map(PathBuf::from))
        .or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
        })
        .unwrap_or_else(std::env::temp_dir);

    base.join("FreeScribe")
}
