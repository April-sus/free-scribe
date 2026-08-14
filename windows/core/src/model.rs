//! Hardware probe and model tiering, ported from the macOS app's `ModelPicker.swift`.
//!
//! The model names differ by necessity: macOS runs CoreML builds through
//! WhisperKit, Windows runs GGML builds through whisper.cpp. The *tiering* is what
//! has to stay comparable, so a given machine gets a like-for-like model.

use sysinfo::System;

#[derive(Debug, Clone)]
pub struct MachineInfo {
    pub cpu: String,
    pub ram_gb: u64,
    pub cores: usize,
}

impl MachineInfo {
    pub fn probe() -> MachineInfo {
        let mut system = System::new();
        system.refresh_memory();
        system.refresh_cpu_all();

        let cpu = system
            .cpus()
            .first()
            .map(|cpu| cpu.brand().trim().to_string())
            .filter(|brand| !brand.is_empty())
            .unwrap_or_else(|| "Unknown CPU".to_string());

        MachineInfo {
            cpu,
            ram_gb: system.total_memory() / 1_073_741_824,
            cores: system.cpus().len(),
        }
    }

    pub fn summary(&self) -> String {
        format!("{} · {} GB RAM · {} cores", self.cpu, self.ram_gb, self.cores)
    }
}

/// Models offered in settings, weakest to strongest, with rough download sizes.
pub const CATALOG: &[(&str, &str, &str)] = &[
    ("ggml-tiny.en", "Tiny (English)", "~75 MB"),
    ("ggml-base.en", "Base (English)", "~142 MB"),
    ("ggml-small.en", "Small (English)", "~466 MB"),
    ("ggml-medium.en", "Medium (English)", "~1.5 GB"),
    ("ggml-large-v3-turbo", "Large v3 Turbo", "~1.6 GB"),
];

pub fn label(id: &str) -> &str {
    CATALOG
        .iter()
        .find(|(model, _, _)| *model == id)
        .map(|(_, label, _)| *label)
        .unwrap_or(id)
}

pub fn size(id: &str) -> &str {
    CATALOG
        .iter()
        .find(|(model, _, _)| *model == id)
        .map(|(_, _, size)| *size)
        .unwrap_or("unknown size")
}

/// Model chosen from hardware limits alone.
///
/// The thresholds match the macOS build so the two platforms make comparable
/// choices. Unlike a Mac there is no Neural Engine to assume, so this is
/// deliberately one step more conservative at the top: `large-v3-turbo` on CPU
/// alone is slow enough to be unpleasant, and GPU offload cannot be assumed.
pub fn recommended(machine: &MachineInfo) -> &'static str {
    match machine.ram_gb {
        0..=7 => "ggml-base.en",
        8..=15 => "ggml-small.en",
        16..=31 => "ggml-medium.en",
        _ => "ggml-large-v3-turbo",
    }
}
