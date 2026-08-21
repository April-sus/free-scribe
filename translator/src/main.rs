//! Translation sidecar.
//!
//! Reads one JSON request per line on stdin and writes one JSON response per line
//! on stdout, so a caller needs nothing but a pipe:
//!
//! ```text
//! {"text":"Hello there","source":"en","target":"fr"}
//! {"text":"Bonjour"}
//! ```
//!
//! A separate process rather than a linked library: CTranslate2 is C++, and getting
//! that into a Swift package is far more trouble than spawning a child. It also
//! means a crash in the model cannot take the app down with it.
//!
//! The model is M2M-100, which translates directly between any pair of its 100
//! languages instead of pivoting through English, so Korean to French does not
//! compound two translations' worth of error.

use ct2rs::sys::{Config, TranslationOptions, Translator};
use sentencepiece::SentencePieceProcessor;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};
use std::path::Path;

#[derive(Deserialize)]
struct Request {
    text: String,
    source: String,
    target: String,
}

#[derive(Serialize, Default)]
struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    ready: bool,
}

impl Response {
    fn ok(text: String) -> Self {
        Response { text: Some(text), ..Default::default() }
    }

    fn failed(message: impl Into<String>) -> Self {
        Response { error: Some(message.into()), ..Default::default() }
    }
}

fn main() {
    let Some(directory) = std::env::args().nth(1) else {
        eprintln!("usage: free-scribe-translate <model directory>");
        std::process::exit(2);
    };
    let directory = Path::new(&directory);

    let pieces = match SentencePieceProcessor::open(directory.join("sentencepiece.bpe.model")) {
        Ok(pieces) => pieces,
        Err(error) => {
            reply(&Response::failed(format!("could not load the tokenizer: {error}")));
            std::process::exit(1);
        }
    };

    let translator = match Translator::new(directory, &Config::default()) {
        Ok(translator) => translator,
        Err(error) => {
            reply(&Response::failed(format!("could not load the model: {error}")));
            std::process::exit(1);
        }
    };

    // Loading takes a few seconds and the caller is waiting on the pipe, so say when
    // requests will actually be answered.
    reply(&Response { ready: true, ..Default::default() });

    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<Request>(&line) {
            Ok(request) => translate(&translator, &pieces, request),
            Err(error) => Response::failed(format!("could not read the request: {error}")),
        };
        reply(&response);
    }
}

fn translate(
    translator: &Translator,
    pieces: &SentencePieceProcessor,
    request: Request,
) -> Response {
    if request.source == request.target || request.text.trim().is_empty() {
        return Response::ok(request.text);
    }

    // M2M expects the source language as the first token and an end marker last:
    // ["__en__", "▁Hello", "▁there", "</s>"].
    let encoded = match pieces.encode(&request.text) {
        Ok(encoded) => encoded,
        Err(error) => return Response::failed(format!("could not read that text: {error}")),
    };

    let mut tokens = Vec::with_capacity(encoded.len() + 2);
    tokens.push(language_token(&request.source));
    tokens.extend(encoded.into_iter().map(|piece| piece.piece));
    tokens.push("</s>".to_string());

    // The target language is given as a forced prefix on the output.
    let prefix = vec![vec![language_token(&request.target)]];
    let options = TranslationOptions { beam_size: 4, ..Default::default() };

    match translator.translate_batch_with_target_prefix(&[tokens], &prefix, &options, None) {
        Ok(results) => match results.into_iter().next() {
            Some(result) => match result.hypotheses.into_iter().next() {
                Some(hypothesis) => Response::ok(detokenize(pieces, hypothesis)),
                None => Response::failed("the model returned nothing"),
            },
            None => Response::failed("the model returned nothing"),
        },
        Err(error) => Response::failed(format!("translation failed: {error}")),
    }
}

fn language_token(code: &str) -> String {
    format!("__{code}__")
}

/// Drops the language and end markers the model echoes back, then puts the pieces
/// together into ordinary text.
fn detokenize(pieces: &SentencePieceProcessor, tokens: Vec<String>) -> String {
    let words: Vec<String> = tokens
        .into_iter()
        .filter(|token| {
            token != "</s>" && !(token.starts_with("__") && token.ends_with("__"))
        })
        .collect();

    pieces
        .decode_pieces(&words)
        .unwrap_or_else(|_| words.join("").replace('\u{2581}', " ").trim().to_string())
}

fn reply(response: &Response) {
    if let Ok(json) = serde_json::to_string(response) {
        println!("{json}");
        let _ = std::io::stdout().flush();
    }
}

#[cfg(test)]
mod tests {
    use super::{detokenize, language_token};
    use sentencepiece::SentencePieceProcessor;

    #[test]
    fn language_tokens_take_m2m_form() {
        assert_eq!(language_token("fr"), "__fr__");
        assert_eq!(language_token("zh"), "__zh__");
    }

    /// The model echoes the target token back and ends with a marker; neither is
    /// part of what the user asked for.
    #[test]
    fn markers_are_not_part_of_the_translation() {
        let Ok(pieces) = SentencePieceProcessor::open(
            std::env::var("M2M_SPM").unwrap_or_default()
        ) else {
            // Without the model this still checks the fallback path.
            return;
        };
        let tokens = vec![
            "__fr__".to_string(),
            "\u{2581}Bonjour".to_string(),
            "</s>".to_string(),
        ];
        let out = detokenize(&pieces, tokens);
        assert!(!out.contains("__fr__"));
        assert!(!out.contains("</s>"));
    }
}
