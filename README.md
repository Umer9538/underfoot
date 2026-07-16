# underfoot

**The OS swaps the AI model under your feet. underfoot keeps the receipts.**

Apple and Google now ship language models *inside* the operating system —
Apple Foundation Models, Gemini Nano — and replace them with OS updates.
No changelog, no warning. Same prompts, different behavior: JSON turns into
prose, a benign health question starts getting refused. Cloud eval tools
can't see any of it, because on-device inference never touches the network.

underfoot is a public observatory for this: a **frozen prompt suite**,
captured against **every OS build we can reach**, with a **diff engine**
that reports exactly which prompts silently changed behavior between two
builds — and an open dataset, because once an OS build is superseded, its
model can never be measured again. Every capture is history that cannot be
re-taken.

**→ The observatory: [docs/index.html](docs/index.html)**
(GitHub Pages) · **→ [Night-one findings](FINDINGS.md)**

## What night one already found

- The macOS 26.5.1 baseline is **perfectly deterministic** under greedy
  sampling — 140/140 runs, byte-identical outputs, even the haiku. Drift
  diffs on this platform are pure signal.
- "Return only the JSON" **returns markdown fences**, deterministically. The
  Urdu translation is confidently wrong — with success status.
- In the iOS 26.3 simulator, the availability API **says `.available`, then
  every generation fails** (`ModelManagerError 1026`, reproduced).
- Framework 1.1.7's guardrail **rejects a benign city-council summarization**
  ("May contain unsafe content") that framework 1.5.2 passes 5/5 — the
  safety layer drifts independently of the model.

## How it works

```
datasets/core-v1.json        28 frozen prompts × 5 greedy runs, 9 failure classes
harness/apple/               macOS capture CLI (Swift)
runner/                      iOS/simulator capture app (Flutter + Swift engine)
captures/apple/<os-build>/   one JSON per build — full outputs, full metadata
diff/                        underfoot_diff: compares two captures, exits 1 on drift
docs/                        the observatory page, generated from the captures
```

Method, in one paragraph: greedy sampling, fresh session per run, five runs
per prompt (so determinism itself is measured), one unrecorded warmup,
sequential execution, thermal state recorded. Every outcome is classified —
`ok` / `refusal` / `unsupported-language` / `context-exceeded` / `error` —
and captures carry the suite's SHA-256, so the diff tool refuses to compare
captures of different suite versions. Refusal flips rank first in every
report. Malformed captures throw rather than silently shrinking coverage.

## Capture a build yourself

```sh
# macOS 26+ with Apple Intelligence enabled:
swift harness/apple/afm_capture.swift datasets/core-v1.json captures

# iPhone (15 Pro or newer) / simulator:
scripts/capture_iphone.sh          # install, run, collect, diff — one shot
```

Then diff any two builds:

```sh
dart diff/bin/underfoot_diff.dart \
  captures/apple/25F80/underfoot-core-v1.capture.json \
  captures/apple/<new-build>/underfoot-core-v1.capture.json
```

```text
underfoot: "underfoot-core" v1 — 26.5.1 (25F80, fm 1.5.2) → 26.3.1 (23D8133, fm 1.1.7)
  28 drifted · 0 stable
  [refusalFlip] summary-council (summarization): now refuses (was answering): …
```

Captures from eligible hardware (Apple-Intelligence iPhones, Pixel 8+ for
the planned Gemini Nano column) are the scarcest resource this project has —
contributions welcome once the repo is public.

## The family

underfoot is the public-data arm of a testing & safety stack for on-device
AI, built on the same principles (determinism, strict parsing, agent-legible
reports):

| Package | Job |
|---|---|
| [`golden_lens`](https://pub.dev/packages/golden_lens) | Visual regressions an AI agent can act on |
| [`llm_replay_eval`](https://pub.dev/packages/llm_replay_eval) | Deterministic record/replay + evals for on-device LLMs |
| [`redact`](https://pub.dev/packages/redact) | On-device PII redaction around every LLM call |
| [`vouch`](https://pub.dev/packages/vouch) | Freeze an eval baseline, fail CI on silent model-swap regressions |
| **`underfoot`** | The public record of what OS-bundled models silently do |

MIT licensed. Built by Muhammad Umer.
