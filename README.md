# driftwatch

**A public record of what the models inside your phone silently do.**

Apple and Google now ship language models *inside* the operating system —
Apple Foundation Models, Gemini Nano — and swap them underneath your app with
OS updates. Same prompts, different behavior, no changelog. Developers find
out from their users.

driftwatch freezes a fixed, versioned prompt suite and captures how the
OS-bundled model answers it — per OS build, per device — building the time
series nobody else can reconstruct later: **once an OS build is superseded,
its model can never be measured again.**

## Method

Rigor is the product. Every capture records:

- the exact **suite version + SHA-256** of the prompt file (captures are only
  comparable within one suite version)
- **greedy sampling**, fresh session per run, sequential execution, one
  unrecorded warmup
- **N runs per prompt** (default 5), so determinism itself is measured — a
  model that answers the same prompt five different ways is a finding
- full platform metadata: OS version + build, hardware model, chip, locale,
  low-power mode, thermal state
- per-run outcome classification: `ok`, `refusal` (guardrail), 
  `unsupported-language`, `context-exceeded`, `error` — with durations

The suite (`datasets/core-v1.json`) targets documented failure classes of
on-device models: structured-JSON breakage, format-compliance drift,
guardrail **over-refusal** (the class behind real health-app regressions
reported on Apple's developer forums), extraction/reasoning wobble,
multilingual coverage, and high-variance creative canaries.

## Repo layout

- `datasets/` — versioned prompt suites (frozen forever once published)
- `harness/apple/` — capture harness for Apple Foundation Models (macOS/iOS)
- `captures/` — the dataset: one JSON per (platform, OS build, suite version)

## Capture a baseline (macOS 26+, Apple Intelligence enabled)

```sh
swift harness/apple/afm_capture.swift datasets/core-v1.json captures
```

Writes `captures/apple/<os-build>/driftwatch-core-v1.capture.json`.

## Status

Early. Currently capturing the Apple column (macOS + iOS). Planned: the
drift diff engine (which prompts flipped between OS builds), Gemini
Nano / Android captures, and a public report site.

Related work by the same author: the testing & safety layer for on-device AI
in Flutter — [golden_lens](https://pub.dev/packages/golden_lens) ·
[llm_replay_eval](https://pub.dev/packages/llm_replay_eval) ·
[redact](https://pub.dev/packages/redact) ·
[vouch](https://pub.dev/packages/vouch).
