//! Usage totals, ported from the macOS app's `Stats.swift`.
//!
//! Kept in a plain JSON file next to the models. Nothing is sent anywhere — there
//! is no network code in this module, and deleting the file resets it.

use chrono::{Duration, Local, NaiveDate};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// What a competent typist manages in prose. Used only to estimate the time
/// dictating saved, so it is an honest ballpark rather than a measurement.
pub const TYPING_WORDS_PER_MINUTE: f64 = 40.0;

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Stats {
    #[serde(default)]
    pub words: u64,
    #[serde(default)]
    pub dictations: u64,
    #[serde(default)]
    pub seconds_spoken: f64,
    #[serde(default)]
    pub first_used: Option<String>,
    #[serde(default)]
    pub last_used: Option<String>,
    /// yyyy-MM-dd to words, for the recent-activity chart.
    #[serde(default)]
    pub by_day: BTreeMap<String, u64>,
}

impl Stats {
    // MARK: Derived

    /// Time typing those words would have taken, less the time actually spent
    /// saying them. Negative early on, which is fine and honest.
    pub fn seconds_saved(&self) -> f64 {
        self.words as f64 / TYPING_WORDS_PER_MINUTE * 60.0 - self.seconds_spoken
    }

    pub fn words_per_minute(&self) -> f64 {
        if self.seconds_spoken > 0.0 {
            self.words as f64 / (self.seconds_spoken / 60.0)
        } else {
            0.0
        }
    }

    pub fn average_words_per_dictation(&self) -> u64 {
        if self.dictations > 0 {
            self.words / self.dictations
        } else {
            0
        }
    }

    /// Words per day for the last `days` days, oldest first, including empty days.
    pub fn recent(&self, days: i64) -> Vec<(NaiveDate, u64)> {
        let today = Local::now().date_naive();
        (0..days)
            .rev()
            .map(|offset| {
                let day = today - Duration::days(offset);
                let key = day.format("%Y-%m-%d").to_string();
                (day, self.by_day.get(&key).copied().unwrap_or(0))
            })
            .collect()
    }

    // MARK: Recording

    /// Updates the totals in memory. Deliberately does not write — the caller
    /// decides when to persist, so counting can be exercised without touching the
    /// real file.
    pub fn record(&mut self, spoken: &str, seconds: f64) {
        let count = spoken.split_whitespace().count() as u64;
        if count == 0 {
            return;
        }

        self.words += count;
        self.dictations += 1;
        self.seconds_spoken += seconds;

        let now = Local::now();
        let stamp = now.to_rfc3339();
        if self.first_used.is_none() {
            self.first_used = Some(stamp.clone());
        }
        self.last_used = Some(stamp);

        *self
            .by_day
            .entry(now.format("%Y-%m-%d").to_string())
            .or_insert(0) += count;

        // Keeps roughly a year of daily buckets. Plenty for the chart, and it stops
        // the file growing without bound. BTreeMap is already in date order.
        while self.by_day.len() > 400 {
            let oldest = self
                .by_day
                .keys()
                .next()
                .cloned()
                .expect("non-empty by construction");
            self.by_day.remove(&oldest);
        }
    }

    // MARK: Storage

    /// `%APPDATA%\FreeScribe\stats.json`, alongside the models.
    pub fn file_path() -> PathBuf {
        crate::data_directory().join("stats.json")
    }

    pub fn load() -> Stats {
        std::fs::read_to_string(Self::file_path())
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        let path = Self::file_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string(self).map_err(std::io::Error::other)?;
        std::fs::write(path, json)
    }

    pub fn erase() {
        let _ = std::fs::remove_file(Self::file_path());
    }
}

/// "2h 14m", "6m", "44s" — for durations shown to a person, not parsed.
pub fn as_duration(seconds: f64) -> String {
    let total = seconds.abs().round() as u64;
    let hours = total / 3600;
    let minutes = (total % 3600) / 60;

    if hours > 0 {
        format!("{hours}h {minutes}m")
    } else if minutes > 0 {
        format!("{minutes}m")
    } else {
        format!("{total}s")
    }
}
