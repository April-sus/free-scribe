# Scribe mode behaviour

The contract both platforms must satisfy. Derived from the NAPLAN *Scribe Rules for
the Writing Test*. If macOS and Windows ever disagree on any line here, that is a bug
in whichever one changed.

This is an aid, not a certification. The source document is the 2015 NAPLAN/BOSTES
version; BOSTES became NESA in 2017 and exam rules drift, so confirm current
requirements with your authority before using this in an exam.

## What the software enforces

| Rule | Behaviour |
|---|---|
| Write word for word | Nothing added, removed, corrected or suggested. Fillers, repeats and false starts all survive. |
| Print in lower case | The whole transcript is lowercased before anything else. |
| No punctuation unless dictated | Every mark Whisper invents is stripped. |
| Never improve the text | Scribe mode is hard-wired never to reach a language model. |

Apostrophes and hyphens **inside** a word are kept — `it's`, `well-known`. Strictly
they are punctuation, but the student is marked on spelling and mangling contractions
would corrupt that.

The **vocabulary** is the second deliberate liberty. Words added to it are given to
the recogniser beforehand, and anything that still comes back sounding like one of
them is replaced by it — in scribe mode as well as everywhere else. The reasoning:
when a student says "onomatopoeia" and the recogniser writes "on O'Matopir", word
for word has already been broken, and putting the word back restores it rather than
improving on it. Only words a person typed into the list are ever matched, so the
software cannot introduce a word nobody said. Punctuation is untouched by this, and
scribe mode still never reaches a language model.

## Spoken commands

Every command needs the literal word `command` in front of it. Without that prefix,
`comma` and `capital` are ordinary words and get written out:

```
you put a comma there and a full stop at the end
→ you put a comma there and a full stop at the end

the dog ran command comma and it was fast command full stop
→ the dog ran, and it was fast.
```

### Punctuation

`full stop` · `fullstop` · `period` · `comma` · `colon` · `semicolon` ·
`question mark` · `exclamation mark` · `exclamation point` · `apostrophe` ·
`hyphen` · `dash` · `slash` · `asterisk` · `ellipsis` · `quote` · `unquote` ·
`quotation mark` · `open quote` · `close quote` · `open bracket` · `close bracket` ·
`open parenthesis` · `close parenthesis` · `new line` · `new paragraph` ·
`next paragraph`

### Capitals

`command capital <word>` capitalises that word. When the target is a single letter
the student is spelling, so following single letters join it:

```
command capital sarah went home   → Sarah went home
command capital y  o              → Yo
```

Spoken capitals are a setting. Turned off, the command words are written out as
spoken — the strictest reading of the rule, where capitals are marked only during the
editing pass.

## What remains a person's job

The software covers the writing phase only. Still required of the supervisor:

- Prior written permission for a scribe, and a student who normally uses one.
- Test instructions given from the Test Administration Handbook.
- The editing pass — the student marks capitals, full stops and paragraphs, recorded
  in red.
- The spelling check — 4 easy, 4 average and 4 difficult words spelt orally, recorded
  in red in three columns.
- Any extra time granted, and recording it where the authority requires.

Read-back is available on both platforms, on request only, never automatically.

## Keeping the platforms honest

`macos/Tests/WhisperFlowTests/` and `windows/core/tests/parity.rs` hold the same cases
under the same names. Change behaviour on one side and you update both suites in the
same commit.

`scripts/parity.sh` goes further and diffs the two real binaries on identical input:

```bash
./scripts/parity.sh
```
