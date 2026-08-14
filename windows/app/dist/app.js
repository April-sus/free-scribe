// Talks to the Rust side. Mirrors what MainWindow.swift does on macOS.
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const LANGUAGES = [
  ["", "Detect automatically"], ["en", "English"], ["es", "Spanish"], ["fr", "French"],
  ["de", "German"], ["pt", "Portuguese"], ["it", "Italian"], ["nl", "Dutch"],
  ["pl", "Polish"], ["ru", "Russian"], ["ja", "Japanese"], ["ko", "Korean"], ["zh", "Chinese"],
];

const ENFORCED = [
  "Writes word for word — nothing added, removed, corrected or suggested.",
  "Prints everything in lower case unless the student asks otherwise.",
  "Adds no punctuation unless asked for by name, with “command” in front of it.",
  "Keeps “um”, repeats and false starts, because removing them would improve the text.",
  "Reads the text back only when asked.",
];

const HUMAN = [
  "Prior written permission for a scribe, and a student who normally uses one.",
  "Test instructions given from the Test Administration Handbook.",
  "The editing pass: the student marks capitals, full stops and paragraphs, recorded in red.",
  "The spelling check: 4 easy, 4 average and 4 difficult words spelt orally, in three columns.",
  "Any extra time granted, and recording it where your authority requires.",
];

const $ = (id) => document.getElementById(id);
let state = null;
let styles = [];

// MARK: Navigation

$("nav").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-pane]");
  if (!button) return;
  for (const other of document.querySelectorAll("nav button")) other.classList.toggle("active", other === button);
  for (const pane of document.querySelectorAll(".pane")) pane.hidden = pane.id !== button.dataset.pane;
});

// MARK: Rendering

function phaseText(phase) {
  switch (phase.kind) {
    case "downloading": return `Downloading model… ${Math.round(phase.value * 100)}%`;
    case "loading": return "Loading model…";
    case "recording": return "Listening…";
    case "transcribing": return "Transcribing…";
    case "error": return phase.value;
    default: return state?.needsSetup ? "Setup needed" : `Ready · ${state?.activeModelLabel ?? ""}`;
  }
}

function fillSelect(element, options, selected) {
  element.replaceChildren();
  for (const [value, label] of options) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    option.selected = value === selected;
    element.append(option);
  }
}

function renderStyles() {
  const container = $("styles");
  container.replaceChildren();

  for (const style of styles) {
    const row = document.createElement("div");
    row.className = "row style-row" + (style.id === state.settings.style ? " selected" : "");
    row.innerHTML = `<span class="dot"></span><div><strong>${style.label}</strong></div>`;
    row.onclick = () => set("style", style.id);
    container.append(row);
  }

  const current = styles.find((style) => style.id === state.settings.style);
  $("style-detail").textContent = current?.detail ?? "";
  $("scribe-rules").hidden = state.settings.style !== "scribe";
}

function renderStats() {
  const stats = state.stats;
  $("s-words").textContent = stats.words.toLocaleString();
  $("s-count").textContent = stats.dictations.toLocaleString();

  const saved = stats.words / 40 * 60 - stats.secondsSpoken;
  $("s-saved").textContent = saved > 0 ? duration(saved) : "—";
  $("s-time").textContent = duration(stats.secondsSpoken);
  $("s-wpm").textContent = `${Math.round(stats.secondsSpoken > 0 ? stats.words / (stats.secondsSpoken / 60) : 0)} wpm`;
  $("s-avg").textContent = `${stats.dictations ? Math.floor(stats.words / stats.dictations) : 0} words`;

  // Last 14 days, including empty ones so gaps read as gaps.
  const days = [];
  for (let offset = 13; offset >= 0; offset--) {
    const date = new Date();
    date.setDate(date.getDate() - offset);
    const key = date.toISOString().slice(0, 10);
    days.push(stats.byDay?.[key] ?? 0);
  }

  const peak = Math.max(...days, 1);
  $("chart").replaceChildren(...days.map((words) => {
    const bar = document.createElement("div");
    bar.style.height = `${Math.max(2, (words / peak) * 100)}%`;
    if (words === 0) bar.className = "empty";
    bar.title = `${words} words`;
    return bar;
  }));
}

function duration(seconds) {
  const total = Math.round(Math.abs(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m`;
  return `${total}s`;
}

function renderModels() {
  const options = [["", `Automatic — ${state.activeModelLabel}`]];
  for (const model of state.downloaded) options.push([model, model]);
  if (state.settings.model && !state.downloaded.includes(state.settings.model)) {
    options.push([state.settings.model, state.settings.model]);
  }
  fillSelect($("modelPick"), options, state.settings.model);

  $("machine").textContent = state.machine;
  $("setup-banner").hidden = !state.needsSetup;
  $("setup-text").textContent = `${state.activeModelLabel} · ${state.activeModelSize} — one download, then it works offline.`;

  const downloading = state.phase.kind === "downloading";
  $("progress-wrap").hidden = !downloading;
  if (downloading) $("progress").value = state.phase.value;

  $("downloaded-card").hidden = state.downloaded.length === 0;
  $("downloaded").replaceChildren(...state.downloaded.map((model) => {
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `<div><strong>${model}</strong></div>`;
    const button = document.createElement("button");
    button.textContent = "Delete";
    button.disabled = model === state.activeModel;
    button.onclick = async () => { await invoke("delete_model", { model }); refresh(); };
    row.append(button);
    return row;
  }));
}

function render() {
  $("status").textContent = phaseText(state.phase);
  $("shortcut").value = state.settings.shortcut;
  $("spokenCapitals").checked = state.settings.spokenCapitals;
  $("launchAtLogin").checked = state.settings.launchAtLogin;
  fillSelect($("language"), LANGUAGES, state.settings.language);
  renderStyles();
  renderModels();
  renderStats();
}

// MARK: Wiring

async function set(key, value) {
  await invoke("set_setting", { key, value });
  await refresh();
}

async function refresh() {
  state = await invoke("get_state");
  render();
}

for (const [id, key] of [["spokenCapitals", "spokenCapitals"], ["launchAtLogin", "launchAtLogin"]]) {
  $(id).addEventListener("change", (event) => set(key, event.target.checked));
}
for (const [id, key] of [["language", "language"], ["inputDevice", "inputDevice"], ["modelPick", "model"]]) {
  $(id).addEventListener("change", (event) => set(key, event.target.value));
}
$("shortcut").addEventListener("change", (event) => set("shortcut", event.target.value));
$("download").addEventListener("click", () => invoke("download_model", { model: state.activeModel }));
$("reset").addEventListener("click", async () => { await invoke("reset_stats"); refresh(); });

listen("phase", (event) => {
  if (!state) return;
  state.phase = event.payload;
  $("status").textContent = phaseText(state.phase);
  renderModels();
  // A finished dictation changes the totals.
  if (event.payload.kind === "idle") refresh();
});

(async () => {
  styles = await invoke("styles");
  $("enforced").replaceChildren(...ENFORCED.map((rule) => Object.assign(document.createElement("li"), { textContent: rule })));
  $("human").replaceChildren(...HUMAN.map((rule) => Object.assign(document.createElement("li"), { textContent: rule })));
  $("marks").textContent = (await invoke("dictated_marks")).join("  ·  ");
  $("stats-path").textContent = await invoke("stats_path");

  const devices = await invoke("list_devices");
  await refresh();
  fillSelect($("inputDevice"), [["", "System default"], ...devices.map((d) => [d.id, d.name])], state.settings.inputDevice);
})();
