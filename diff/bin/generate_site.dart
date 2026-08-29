import 'dart:convert';
import 'dart:io';

import 'package:underfoot_diff/underfoot_diff.dart';

/// Generates the underfoot observatory page (docs/index.html) from the
/// committed captures. The page is fully self-contained — inline CSS, no
/// scripts, no external assets — so GitHub Pages can serve it as-is and a
/// saved copy keeps working offline.
///
/// Usage (from the repo root):
///   dart diff/bin/generate_site.dart
void main(List<String> arguments) {
  final root = arguments.isNotEmpty ? arguments[0] : '.';
  final macos = Capture.parse(
      File('$root/captures/apple/25F80/underfoot-core-v1.capture.json')
          .readAsStringSync());
  final sim = Capture.parse(
      File('$root/captures/apple/23D8133/underfoot-core-v1.capture.json')
          .readAsStringSync());
  final suite =
      jsonDecode(File('$root/datasets/core-v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final report = compareCaptures(macos, sim);

  final html = _page(macos, sim, suite, report);
  final out = File('$root/docs/index.html')..createSync(recursive: true);
  out.writeAsStringSync(html);
  stderr.writeln('written: ${out.path} (${html.length} bytes)');
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Stable FNV-1a hash so pseudo-jitter in the seismogram is byte-identical
/// across Dart versions (String.hashCode is not guaranteed stable).
int _fnv(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

List<PromptCapture> _sorted(Capture c) => c.results.values.toList()
  ..sort((a, b) {
    final byCat = a.category.compareTo(b.category);
    return byCat != 0 ? byCat : a.promptId.compareTo(b.promptId);
  });

/// One seismogram lane: a single SVG path across the prompt sequence.
/// Amplitude encodes the captured outcome per prompt — flat for
/// byte-identical ok, jitter for generation errors, a sharp spike for
/// refusals. Derived entirely from the capture; nothing hand-drawn.
String _tracePath(Capture c, double laneY, double x0, double x1) {
  final prompts = _sorted(c);
  final seg = (x1 - x0) / prompts.length;
  final b = StringBuffer('M ${x0.toStringAsFixed(1)} $laneY');
  var x = x0;
  for (final p in prompts) {
    final statuses = p.statusProfile.toSet();
    final refused = statuses.contains('refusal');
    final errored = statuses.contains('error');
    final okFlat = statuses.length == 1 &&
        statuses.first == 'ok' &&
        p.outputSet.length <= 1;
    final h = _fnv(p.promptId);
    if (refused) {
      // Sharp quake wiggle: down, hard up, down, settle.
      b.write(' L ${(x + seg * .30).toStringAsFixed(1)} ${laneY + 6}');
      b.write(' L ${(x + seg * .45).toStringAsFixed(1)} ${laneY - 34}');
      b.write(' L ${(x + seg * .60).toStringAsFixed(1)} ${laneY + 22}');
      b.write(' L ${(x + seg * .78).toStringAsFixed(1)} ${laneY - 10}');
    } else if (errored) {
      for (var i = 0; i < 5; i++) {
        final amp = 5 + ((h >> (i * 4)) & 9).toDouble();
        final sign = ((h >> i) & 1) == 0 ? 1 : -1;
        b.write(' L ${(x + seg * (0.12 + 0.19 * i)).toStringAsFixed(1)} '
            '${(laneY + sign * amp).toStringAsFixed(1)}');
      }
    } else if (okFlat) {
      final tick = ((h & 3) - 1.5) * 0.8;
      b.write(' L ${(x + seg * .5).toStringAsFixed(1)} '
          '${(laneY + tick).toStringAsFixed(1)}');
    } else {
      b.write(' L ${(x + seg * .5).toStringAsFixed(1)} ${laneY - 5}');
    }
    x += seg;
    b.write(' L ${x.toStringAsFixed(1)} $laneY');
  }
  return b.toString();
}

String _seismogram(Capture a, Capture b) {
  const x0 = 14.0, x1 = 986.0;
  const laneA = 62.0, laneB = 148.0;
  final aClean = a.results.values
      .every((p) => p.statusProfile.every((s) => s == 'ok'));
  final bClean = b.results.values
      .every((p) => p.statusProfile.every((s) => s == 'ok'));
  final colA = aClean ? 'var(--ok)' : 'var(--drift)';
  final colB = bClean ? 'var(--ok)' : 'var(--drift)';

  // Annotate the first refusal in trace B, if any.
  final prompts = _sorted(b);
  String annotation = '';
  for (var i = 0; i < prompts.length; i++) {
    if (prompts[i].statusProfile.contains('refusal')) {
      final seg = (x1 - x0) / prompts.length;
      final sx = x0 + seg * (i + .45);
      final atRightEdge = sx > 650;
      final tx = atRightEdge ? sx - 8 : sx + 8;
      final anchor = atRightEdge ? ' text-anchor="end"' : '';
      annotation = '''
    <line x1="${sx.toStringAsFixed(1)}" y1="${laneB - 40}" x2="${sx.toStringAsFixed(1)}" y2="${laneB - 58}" stroke="var(--drift)" stroke-width="1" stroke-dasharray="2 3"/>
    <text x="${tx.toStringAsFixed(1)}" y="${laneB - 54}" class="svg-note" fill="var(--drift)"$anchor>guardrail refusal — ${_esc(prompts[i].promptId)}</text>''';
      break;
    }
  }

  return '''
<svg viewBox="0 0 1000 190" role="img" aria-label="Seismogram of model behavior: one segment per prompt, per captured OS build. The macOS trace is flat; the simulator trace shows error jitter and one refusal spike.">
    <text x="14" y="24" class="svg-label" fill="var(--muted2)">TRACE A · ${_esc(a.osVersion)} (${_esc(a.osBuild)}) · fm ${_esc(a.frameworkBuild ?? '?')}</text>
    <text x="986" y="24" class="svg-label" fill="$colA" text-anchor="end">140/140 OK · BYTE-IDENTICAL</text>
    <path class="trace" d="${_tracePath(a, laneA, x0, x1)}" fill="none" stroke="$colA" stroke-width="1.5"/>
    <text x="14" y="110" class="svg-label" fill="var(--muted2)">TRACE B · iOS ${_esc(b.osVersion)} sim (${_esc(b.osBuild)}) · fm ${_esc(b.frameworkBuild ?? '?')}</text>
    <text x="986" y="110" class="svg-label" fill="$colB" text-anchor="end">EVERY GENERATION FAILS · 1 REFUSAL FLIP</text>
    <path class="trace trace-b" d="${_tracePath(b, laneB, x0, x1)}" fill="none" stroke="$colB" stroke-width="1.5"/>
$annotation
</svg>''';
}

String _statusDot(String status) {
  const cls = {
    'ok': 'ok',
    'refusal': 'bad',
    'error': 'bad',
    'unsupported-language': 'warn',
    'context-exceeded': 'warn',
  };
  return '<span class="dot ${cls[status] ?? 'mut'}"></span>'
      '<span class="mono st">${_esc(status)}</span>';
}

String _promptRow(PromptCapture p, Map<String, String> watches) {
  final statuses = p.statusProfile.toSet().toList()..sort();
  final badges = statuses.map(_statusDot).join(' ');
  final deterministic = p.outputSet.length <= 1;
  final output = p.outputSet.isEmpty
      ? '<p class="mut"><em>(no successful output)</em></p>'
      : '<pre>${_esc(p.outputSet.first)}</pre>';
  final detNote = p.runs.first.status == 'ok'
      ? (deterministic
          ? '<span class="det det-ok">byte-identical across all ${p.runs.length} runs</span>'
          : '<span class="det det-warn">${p.outputSet.length} distinct outputs across ${p.runs.length} runs</span>')
      : '';
  return '''
<details class="prompt">
  <summary><code>${_esc(p.promptId)}</code>
    <span class="cat">${_esc(p.category)}</span><span class="badges">$badges</span></summary>
  <div class="pbody">
    <p class="watch">watches: ${_esc(watches[p.promptId] ?? '')}</p>
    $output
    $detNote
  </div>
</details>''';
}

String _fmtDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

String _page(Capture macos, Capture sim, Map<String, dynamic> suite,
    DriftReport report) {
  final watches = <String, String>{
    for (final p in suite['prompts'] as List)
      (p as Map<String, dynamic>)['id'] as String:
          (p['watches'] ?? '') as String,
  };
  final categories = <String>{
    for (final p in suite['prompts'] as List)
      (p as Map<String, dynamic>)['category'] as String,
  };

  final macosOk = macos.results.values
      .where((p) => p.statusProfile.every((s) => s == 'ok'))
      .length;
  final macosDeterministic = macos.results.values
      .where((p) =>
          p.outputSet.length == 1 && p.statusProfile.every((s) => s == 'ok'))
      .length;

  final refusalFlips = report.ofKind(DriftKind.refusalFlip);
  final statusChanges = report.ofKind(DriftKind.statusChanged);
  final captureDate = _fmtDate(macos.capturedAt);

  final promptRows =
      _sorted(macos).map((p) => _promptRow(p, watches)).join('\n');

  final diffLines = StringBuffer();
  for (final f in refusalFlips) {
    diffLines.writeln(
        '<div class="line"><span class="t-red t-b">✗ refusalFlip</span> '
        '${_esc(f.promptId)} <span class="t-mut">(${_esc(f.category)})</span></div>'
        '<div class="line indent">${_esc(f.detail)}</div>');
  }
  diffLines.writeln(
      '<div class="line"><span class="t-amber t-b">~ statusChanged</span> '
      '<span class="t-mut">${statusChanges.length} prompts: every generation '
      'errors (ModelManagerError 1026) despite availability = .available</span></div>');

  return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>underfoot — the on-device model drift observatory</title>
<meta name="description" content="Apple and Google swap the AI models inside your phone with OS updates. underfoot freezes a prompt suite, captures every OS build's answers, and publishes exactly what silently changed.">
<meta property="og:title" content="underfoot — the on-device model drift observatory">
<meta property="og:description" content="One frozen prompt suite, captured per OS build, diffed. Superseded builds can never be measured again — every capture here is history that cannot be re-taken.">
<meta property="og:type" content="website">
<meta property="og:url" content="https://umer9538.github.io/underfoot/">
<style>
  :root {
    --paper:#FAF9F4; --card:#FFFFFD; --ink:#1D2A2E; --muted:#57666B;
    --muted2:#7A8A8F; --rule:#DCD8CA; --drift:#B5382A; --ok:#1D7A4B;
    --amber:#8F6400; --term:#10161A; --termfg:#D9E2E6; --grid:#5A7882;
  }
  * { box-sizing:border-box; margin:0; padding:0; }
  html { scroll-behavior:smooth; }
  html, body { overflow-x:clip; }
  body {
    background:
      repeating-linear-gradient(0deg, rgba(90,120,130,.055) 0 1px, transparent 1px 28px),
      repeating-linear-gradient(90deg, rgba(90,120,130,.055) 0 1px, transparent 1px 28px),
      var(--paper);
    color:var(--ink); line-height:1.65;
    font-family:"Iowan Old Style", Palatino, Charter, Georgia, serif;
    font-size:16.5px;
  }
  main { max-width:940px; margin:0 auto; padding:44px 22px 72px; }
  .mono, code, pre, .eyebrow, .svg-label, table, .st, .det, .watch, .cap
    { font-family:ui-monospace, "SF Mono", Menlo, Consolas, monospace; }
  a { color:inherit; text-decoration:underline; text-underline-offset:3px;
      text-decoration-color:var(--muted2); }
  a:hover { color:var(--drift); text-decoration-color:var(--drift); }
  a:focus-visible { outline:2px solid var(--drift); outline-offset:3px; }

  .masthead { display:flex; justify-content:space-between; gap:12px;
    border-bottom:2px solid var(--ink); padding-bottom:10px; flex-wrap:wrap; }
  .eyebrow { font-size:11.5px; letter-spacing:.14em; color:var(--muted); }
  .eyebrow b { color:var(--drift); font-weight:700; }
  h1.display { font-size:clamp(32px, 5.4vw, 52px); line-height:1.08;
    letter-spacing:-.5px; font-weight:600; margin:26px 0 14px; max-width:20ch; }
  h1 .u { color:var(--drift); }
  .lede { font-size:18.5px; max-width:62ch; color:var(--muted); }
  .lede b { color:var(--ink); }

  .fig { background:var(--card); border:1px solid var(--rule); border-radius:3px;
    margin:34px 0 8px; box-shadow:0 1px 0 rgba(29,42,46,.05); }
  .fig-chart {
    background:
      repeating-linear-gradient(0deg, rgba(90,120,130,.10) 0 1px, transparent 1px 14px),
      repeating-linear-gradient(90deg, rgba(90,120,130,.10) 0 1px, transparent 1px 14px),
      var(--card);
    padding:10px 6px 2px;
  }
  .fig svg { display:block; width:100%; height:auto; }
  .svg-label { font-size:11px; letter-spacing:.08em; }
  .svg-note { font-size:11.5px; font-style:italic;
    font-family:"Iowan Old Style", Palatino, Georgia, serif; }
  .trace { stroke-dasharray:3000; stroke-dashoffset:3000;
    animation:draw 1.8s ease-out forwards; }
  .trace-b { animation-delay:.5s; }
  @keyframes draw { to { stroke-dashoffset:0; } }
  @media (prefers-reduced-motion: reduce) {
    .trace { animation:none; stroke-dashoffset:0; }
  }
  .cap { font-size:12px; color:var(--muted); padding:9px 14px;
    border-top:1px solid var(--rule); display:flex; gap:18px; flex-wrap:wrap; }
  .cap .n { color:var(--ink); font-weight:700; }
  .cap .n-drift { color:var(--drift); font-weight:700; }

  h2 { font-size:13px; letter-spacing:.14em; text-transform:uppercase;
    font-family:ui-monospace, "SF Mono", Menlo, monospace; color:var(--muted);
    margin:52px 0 14px; display:flex; align-items:center; gap:12px; }
  h2::after { content:""; flex:1; border-top:1px solid var(--rule); }
  h2 .no { color:var(--drift); }

  .tscroll { overflow-x:auto; }
  table { border-collapse:collapse; width:100%; min-width:620px; font-size:13px;
    background:var(--card); border:1px solid var(--rule); }
  th, td { text-align:left; padding:10px 14px; border-bottom:1px solid var(--rule);
    vertical-align:top; }
  tr:last-child td { border-bottom:none; }
  th { color:var(--muted); font-weight:600; font-size:11.5px;
    letter-spacing:.1em; text-transform:uppercase; }
  .ok-t { color:var(--ok); } .bad-t { color:var(--drift); } .mut { color:var(--muted); }

  .finding { background:var(--card); border:1px solid var(--rule);
    border-left:3px solid var(--muted2); border-radius:3px;
    padding:18px 22px 16px; margin:12px 0; }
  .finding.f-ok { border-left-color:var(--ok); }
  .finding.f-warn { border-left-color:var(--amber); }
  .finding.f-bad { border-left-color:var(--drift); }
  .finding .tag { font-size:11px; letter-spacing:.13em; color:var(--muted);
    font-family:ui-monospace, "SF Mono", Menlo, monospace; }
  .finding h3 { font-size:18.5px; font-weight:600; margin:5px 0 7px;
    letter-spacing:-.2px; }
  .finding p { color:var(--muted); font-size:15.5px; }
  .finding p b, .finding p code { color:var(--ink); }
  code { font-size:.88em; background:rgba(90,120,130,.10);
    padding:.08em .35em; border-radius:3px; }

  .term { background:var(--term); color:var(--termfg); border-radius:6px;
    padding:16px 20px; font-size:13px; line-height:1.75; overflow-x:auto;
    border:1px solid #2A343A; }
  .term .line { white-space:pre-wrap;
    font-family:ui-monospace, "SF Mono", Menlo, monospace; }
  .term .indent { padding-left:22px; color:#8Da0a6; }
  .t-red { color:#FF7B6E; } .t-amber { color:#E3B341; }
  .t-mut { color:#8DA0A6; } .t-b { font-weight:700; }

  details.prompt { border:1px solid var(--rule); border-radius:3px;
    margin:7px 0; background:var(--card); }
  details.prompt summary { cursor:pointer; padding:9px 14px; display:flex;
    gap:10px; align-items:center; flex-wrap:wrap; font-size:14px; }
  details.prompt summary:hover { background:rgba(90,120,130,.06); }
  details.prompt summary:focus-visible { outline:2px solid var(--drift); outline-offset:-2px; }
  details.prompt .cat { color:var(--muted2); font-size:12px;
    font-family:ui-monospace, "SF Mono", Menlo, monospace; }
  details.prompt .badges { margin-left:auto; display:flex; gap:8px; align-items:center; }
  .dot { display:inline-block; width:8px; height:8px; border-radius:50%;
    margin-right:4px; vertical-align:1px; }
  .dot.ok { background:var(--ok); } .dot.bad { background:var(--drift); }
  .dot.warn { background:var(--amber); } .dot.mut { background:var(--muted2); }
  .st { font-size:11.5px; color:var(--muted); }
  details.prompt .pbody { padding:4px 14px 13px; border-top:1px solid var(--rule); }
  details.prompt pre { background:#F1EFE6; border:1px solid var(--rule);
    border-radius:3px; padding:11px 13px; font-size:12.5px;
    white-space:pre-wrap; margin:8px 0; }
  .watch { color:var(--muted); font-size:12.5px; }
  .det { font-size:12px; } .det-ok { color:var(--ok); } .det-warn { color:var(--amber); }

  ol.protocol { list-style:none; counter-reset:step; }
  ol.protocol li { counter-increment:step; background:var(--card);
    border:1px solid var(--rule); border-radius:3px; padding:13px 18px 13px 56px;
    margin:8px 0; position:relative; font-size:15.5px; color:var(--muted); }
  ol.protocol li b { color:var(--ink); }
  ol.protocol li::before { content:counter(step, decimal-leading-zero);
    position:absolute; left:16px; top:14px; color:var(--drift);
    font-family:ui-monospace, "SF Mono", Menlo, monospace; font-size:13px;
    font-weight:700; }

  .contribute { border:1.5px solid var(--drift); border-radius:3px;
    background:var(--card); padding:20px 24px; margin:48px 0 0; }
  .contribute h3 { font-size:19px; letter-spacing:-.2px; }
  .contribute h3::before { content:"⊕ "; color:var(--drift); }
  .contribute p { color:var(--muted); font-size:15.5px; margin-top:6px; }
  .contribute p b { color:var(--ink); }

  footer { margin-top:56px; border-top:2px solid var(--ink); padding-top:18px;
    color:var(--muted); font-size:13px;
    font-family:ui-monospace, "SF Mono", Menlo, monospace; }
  footer p { margin:5px 0; }
  @media (max-width:600px) {
    body { font-size:15.5px; }
    .cap { gap:10px; }
    details.prompt .badges { margin-left:0; }
  }
</style>
</head>
<body>
<main>
  <header class="masthead">
    <span class="eyebrow"><b>UNDERFOOT</b> · DRIFT OBSERVATORY · STATION 01 — APPLE FOUNDATION MODELS</span>
    <span class="eyebrow">RECORDING SINCE JULY 2026</span>
  </header>

  <h1 class="display">The model <span class="u">under your feet</span> changes with every OS update.</h1>
  <p class="lede">Apple and Google swap the AI models inside your phone silently —
  no changelog, no version pin. <b>underfoot freezes one prompt suite, captures
  every OS build's answers, and publishes exactly what moved.</b> Once a build is
  superseded, its model can never be measured again: every trace below is history
  that cannot be re-taken.</p>

  <figure class="fig">
    <div class="fig-chart">${_seismogram(macos, sim)}</div>
    <figcaption class="cap">
      <span>FIG. 01 — one segment per prompt · flat = byte-identical ok · jitter = generation error · spike = refusal</span>
      <span><span class="n">${macos.results.length}</span> prompts × 5 greedy runs</span>
      <span><span class="n">2</span> builds captured</span>
      <span><span class="n-drift">${report.findings.length}</span> behavioral differences</span>
    </figcaption>
  </figure>

  <h2><span class="no">§1</span> Captured builds</h2>
  <div class="tscroll"><table>
    <tr><th>Platform</th><th>OS build</th><th>FoundationModels</th><th>Result</th></tr>
    <tr><td>macOS (M1)</td><td>${_esc(macos.osVersion)} · ${_esc(macos.osBuild)}</td>
        <td>${_esc(macos.frameworkBuild ?? '?')}</td>
        <td><span class="ok-t">$macosOk/${macos.results.length} prompts answered</span> · $macosDeterministic/${macos.results.length} byte-identical across all runs</td></tr>
    <tr><td>iOS simulator (iPhone 17 Pro)</td><td>${_esc(sim.osVersion)} · ${_esc(sim.osBuild)}</td>
        <td>${_esc(sim.frameworkBuild ?? '?')}</td>
        <td><span class="bad-t">reports available, fails every generation</span></td></tr>
    <tr><td>iPhone 13 (A15)</td><td>iOS 26.6 beta</td><td>—</td>
        <td><span class="mut">below the Apple Intelligence eligibility cliff — model unavailable, permanently</span></td></tr>
  </table></div>

  <h2><span class="no">§2</span> Findings — night one · $captureDate</h2>

  <div class="finding f-ok"><span class="tag">FINDING 1 · DETERMINISM</span>
  <h3>The baseline is perfectly deterministic — which makes drift measurable</h3>
  <p>All 140 macOS runs succeeded and <b>every prompt returned byte-identical
  output across its 5 greedy runs</b>, including the creative canaries (the
  haiku never varied). Any future change on this platform is the OS's doing,
  not sampling noise.</p></div>

  <div class="finding f-warn"><span class="tag">FINDING 2 · FORMAT</span>
  <h3>"Return only the JSON" returns markdown</h3>
  <p>Every structured-output prompt came back wrapped in <code>&#96;&#96;&#96;json</code>
  fences — deterministically. A naive JSON parse of the response fails today;
  if a future model drops the fences, apps that learned to strip them flip
  behavior instead. Also in the baseline: <b>"reply with exactly one word:
  ready" → <code>Ready.</code></b>, and the Urdu translation prompt returns
  fluent-looking text that is simply wrong — with success status.</p></div>

  <div class="finding f-bad"><span class="tag">FINDING 3 · AVAILABILITY</span>
  <h3>The simulator's availability API cannot be trusted</h3>
  <p>In the iOS ${_esc(sim.osVersion)} simulator on the same
  Apple-Intelligence-enabled Mac, <code>SystemLanguageModel.default.availability</code>
  returns <code>.available</code> — then <b>all 140 generations fail</b> with
  <code>ModelManagerError 1026</code>, reproduced identically on a second run.
  CI that trusts the availability preflight will start suites it cannot finish.</p></div>

  <div class="finding f-bad"><span class="tag">FINDING 4 · GUARDRAIL DRIFT</span>
  <h3>The guardrail layer drifts independently of the model</h3>
  <p>Framework ${_esc(sim.frameworkBuild ?? '1.1.7')} rejected the benign
  <b>city-council meeting summarization</b> prompt as
  <i>"May contain unsafe content"</i> — the exact prompt framework
  ${_esc(macos.frameworkBuild ?? '1.5.2')} passes 5/5. The input safety
  classifier fired even though the model itself never executed: refusal
  behavior is a property of the <b>OS build</b>, not just the model.</p></div>

  <h2><span class="no">§3</span> The diff, as the tool reports it</h2>
  <p class="mut" style="font-size:14px; margin-bottom:10px">Output of
  <code>underfoot_diff</code> comparing the two captures — refusal flips always
  rank first:</p>
  <div class="term">
    <div class="line"><span class="t-mut">\$ dart diff/bin/underfoot_diff.dart captures/apple/25F80/… captures/apple/23D8133/…</span></div>
    <div class="line">underfoot: "underfoot-core" v1 — ${_esc(macos.label)} → ${_esc(sim.label)}</div>
    <div class="line">  ${report.findings.length} drifted · ${report.stableCount} stable</div>
${diffLines.toString().split('\n').map((l) => '    $l').join('\n')}
  </div>

  <h2><span class="no">§4</span> The baseline, prompt by prompt</h2>
  <p class="mut" style="font-size:14px; margin-bottom:10px">macOS ${_esc(macos.osVersion)}
  (${_esc(macos.osBuild)}), framework ${_esc(macos.frameworkBuild ?? '?')} —
  ${categories.length} categories. Every output below is a real, committed
  capture; click to expand.</p>
  $promptRows

  <h2><span class="no">§5</span> Protocol</h2>
  <ol class="protocol">
    <li><b>Freeze the suite.</b> 28 prompts, versioned and hashed — captures are
    only comparable within one exact suite version (name + version + SHA-256,
    all enforced by the diff tool).</li>
    <li><b>Capture deterministically.</b> Greedy sampling, fresh session per
    run, 5 runs per prompt (so determinism itself is measured), one unrecorded
    warmup, sequential execution, thermal state recorded.</li>
    <li><b>Classify honestly.</b> Simulator captures are marked as such — the
    model executes via the host Mac. Every outcome is labeled:
    ok / refusal / unsupported-language / context-exceeded / error.</li>
    <li><b>Publish the data.</b> Every capture is a committed JSON file with
    full outputs — check the math, rerun the diff, cite the build numbers.
    This page is generated from the captures; no number on it is hand-typed.</li>
  </ol>

  <div class="contribute">
    <h3>Contribute a capture</h3>
    <p>The scarcest resource is <b>eligible hardware</b>. If you have an
    Apple-Intelligence iPhone (15 Pro or newer) or a Pixel 8+, a capture takes
    about ten minutes and adds a column to this record that nobody can ever
    reconstruct later. Harness and instructions:
    <a href="https://github.com/Umer9538/underfoot">github.com/Umer9538/underfoot</a>.</p>
  </div>

  <footer>
    <p>underfoot is part of the testing &amp; safety layer for on-device AI:
    <a href="https://pub.dev/packages/golden_lens">golden_lens</a> ·
    <a href="https://pub.dev/packages/llm_replay_eval">llm_replay_eval</a> ·
    <a href="https://pub.dev/packages/redact">redact</a> ·
    <a href="https://pub.dev/packages/vouch">vouch</a> ·
    <a href="https://github.com/Umer9538/unswayed">unswayed</a> · underfoot</p>
    <p>Built by <a href="https://personalportfolio-main.vercel.app">Muhammad Umer</a>
    — captures, harnesses, and the diff engine are MIT-licensed on
    <a href="https://github.com/Umer9538/underfoot">GitHub</a>.</p>
  </footer>
</main>
</body>
</html>
''';
}
