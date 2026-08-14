//! Prints what each style does to a line, in the same format as the macOS app's
//! `--clean` flag, so the two implementations can be diffed directly:
//!
//! ```text
//! cargo run -q --example clean -- "some dictated text"
//! './Free Scribe.app/Contents/MacOS/FreeScribe' --clean "some dictated text"
//! ```

use free_scribe_core::cleanup::{apply, DictationStyle};

fn main() {
    let spoken: String = std::env::args().skip(1).collect::<Vec<_>>().join(" ");

    for style in DictationStyle::ALL {
        let name = match style {
            DictationStyle::Verbatim => "verbatim",
            DictationStyle::Scribe => "scribe",
            DictationStyle::Tidy => "tidy",
            DictationStyle::Polished => "polished",
        };
        println!("{:<9} {}", name, apply(&spoken, style, true));
    }
}
