# Compliance plan

What has to be true before Free Scribe can be given away, sold, or put in front of a
student in an exam. Written after auditing the 460 Rust crates and 4 Swift packages the
two apps depend on.

Nothing in here is legal advice. The dependency findings are facts you can verify; the
rest is a checklist to take to a lawyer so you are paying them to answer questions
rather than to discover them.

## Where things stand

Good news first: **no dependency restricts you.** Everything is MIT, Apache-2.0,
Unlicense, Zlib or Unicode-3.0. No GPL, no AGPL, no non-commercial clauses. You may
license Free Scribe however you like, including closed-source and paid.

Two footnotes: `r-efi` offers LGPL as one of three options, so choose MIT and it is
moot. Five crates pulled in by Tauri (`cssparser`, `selectors`, `dtoa-short`,
`cssparser-macros`, `option-ext`) are MPL-2.0 — file-level copyleft, which is fine in a
commercial closed product provided those files are not modified. They are not.

**One actual violation today:** the apps ship binaries without the copyright notices
that MIT and Apache-2.0 require. That applies to every build already produced,
including the CI installer.

## Phase 0 — the decision everything hangs off

**Owner: you, with advice.** Nothing else can be finished until the licence is chosen,
because it determines the `LICENSE` file, the headers, and what the paid edition can
even be.

The conventional shape for "free version plus paid school edition" is AGPL-3.0 for the
public repo plus a separate commercial licence you sell. It keeps the free version open
while stopping a competitor from taking it closed, and because you hold the copyright
you can license it twice.

Ask a lawyer these three, in this order:

1. **Do I hold enforceable copyright?** Most of this code was written by an AI.
   Australian copyright generally requires a human author, and machine-generated work
   may not attract protection. This determines whether dual-licensing is available at
   all, or whether the business is services and support around an unprotectable
   codebase. Answer this before spending money on anything else.
2. Given the answer, is AGPL + commercial the right structure?
3. What entity should hold it?

## Phase 1 — attribution (fixes the current violation)

**Owner: me. Mechanical and verifiable.**

- Generate `THIRD-PARTY-NOTICES.txt` from the real dependency graph — `cargo-about`
  for the Rust side, plus the four Swift package licences (WhisperKit,
  KeyboardShortcuts, swift-transformers, and their transitive deps).
- Bundle it in **both** installers: `Free Scribe.app/Contents/Resources/` on macOS, and
  the MSI/NSIS payload on Windows. In the repo alone does not satisfy the licences.
- Surface it in the app's About pane, so a user can actually read it.
- Add a short model-attribution section: Whisper weights are MIT (OpenAI); the GGML and
  CoreML builds are third-party redistributions, downloaded at runtime rather than
  bundled.

**Done when:** a fresh install of each platform contains the notices file, and it lists
every crate and package with a licence that requires attribution.

## Phase 2 — positioning

**Owner: me, then you to approve the wording.**

- Add the chosen `LICENSE` file; replace `license = "UNLICENSED"` in
  `windows/Cargo.toml` and set the equivalent on the Swift side.
- Remove "Wispr Flow's dictation loop" from both READMEs. Accurate as description,
  but it invites a false-association claim the moment money is involved.
- Keep `docs/scribe-rules.md` as paraphrase. The rules themselves are procedures and
  not copyrightable; ACARA/NESA own the PDF's wording.
- Keep an explicit no-endorsement line wherever NAPLAN or NESA is named. A school will
  otherwise assume approval.
- Re-verify the rules against the **current** NESA document. Ours is the 2015
  NAPLAN/BOSTES version; BOSTES became NESA in 2017 and exam rules drift.

**Done when:** no reference to another product implies affiliation, and every NAPLAN
mention sits next to a disclaimer.

## Phase 3 — keeping it compliant

**Owner: me.**

- Add `cargo-deny` to CI with an allowlist of permissive licences, so a future
  dependency cannot quietly introduce GPL or AGPL.
- Regenerate the notices file as part of the installer build rather than by hand, so it
  cannot drift from the actual dependency graph.

**Done when:** adding a GPL crate fails CI.

## Phase 4 — distribution

**Owner: you. Costs money, no way around it.**

- **Windows code-signing certificate** (OV or EV). Unsigned installers trigger
  SmartScreen and most school IT will not deploy them.
- **Apple Developer ID** plus notarisation for the macOS build.
- Trademark search on "Free Scribe" in the relevant classes before printing anything or
  registering a domain.

**Done when:** an installer runs on a clean machine with no security warning.

## Phase 5 — the documents a school will ask for

**Owner: lawyer drafts, I can prepare the technical content.**

- **Privacy statement.** Local-only processing is the strongest thing you have, but it
  has to be in writing: what is stored (`stats.json`, models, settings), where, that
  nothing is transmitted after the model download, and retention. Student data means
  the Privacy Act and state education policies apply, and under-18 raises the bar.
- **EULA with liability limits**, written for the exam context specifically. Note that
  Australian Consumer Law guarantees cannot be disclaimed, so a US-style "as is" clause
  will not fully hold here.
- **Accessibility conformance statement.** This is assistive technology sold into
  education; procurement will likely ask for WCAG 2.2 or EN 301 549 alignment.
- **Professional indemnity insurance**, given that a failure during an exam has real
  consequences for a student.

## Phase 6 — evidence for procurement

**Owner: me, and it mostly exists already.**

- The parity suite and `scripts/parity.sh` are evidence that both platforms produce
  identical transcripts — worth stating plainly, since it is the sort of claim
  procurement asks you to substantiate.
- `docs/scribe-rules.md` is already the behaviour contract: what the software enforces
  and what remains a supervisor's job. That division is the honest core of the pitch.
- Versioned releases and a changelog, so a school knows what it deployed.

## Order of work

Phase 1 can start immediately — it fixes a live violation and does not depend on the
licence choice. Phase 2 needs the licence decision. Phases 4 and 5 cost money and time,
so start Phase 0's first question now: everything commercial depends on the answer.
