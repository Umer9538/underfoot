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

String _statusBadge(String status) {
  const colors = {
    'ok': '#3fb950',
    'refusal': '#f85149',
    'unsupported-language': '#d29922',
    'context-exceeded': '#d29922',
    'error': '#f85149',
  };
  final color = colors[status] ?? '#8b949e';
  return '<span class="badge" style="color:$color;border-color:$color">'
      '${_esc(status)}</span>';
}

String _promptRow(PromptCapture p, Map<String, String> watches) {
  final statuses = p.statusProfile.toSet();
  final badge = statuses.length == 1
      ? _statusBadge(statuses.first)
      : statuses.map(_statusBadge).join(' ');
  final deterministic = p.outputSet.length <= 1;
  final output = p.outputSet.isEmpty
      ? '<em>(no successful output)</em>'
      : '<pre>${_esc(p.outputSet.first)}</pre>';
  final detNote = p.runs.first.status == 'ok'
      ? (deterministic
          ? '<span class="det ok-det">identical across all ${p.runs.length} runs</span>'
          : '<span class="det">${p.outputSet.length} distinct outputs across ${p.runs.length} runs</span>')
      : '';
  return '''
<details class="prompt">
  <summary><code>${_esc(p.promptId)}</code>
    <span class="cat">${_esc(p.category)}</span> $badge</summary>
  <div class="body">
    <p class="watch">watches: ${_esc(watches[p.promptId] ?? '')}</p>
    $output
    $detNote
  </div>
</details>''';
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

  final promptRows = (macos.results.values.toList()
        ..sort((a, b) {
          final byCat = a.category.compareTo(b.category);
          return byCat != 0 ? byCat : a.promptId.compareTo(b.promptId);
        }))
      .map((p) => _promptRow(p, watches))
      .join('\n');

  final diffLines = StringBuffer();
  for (final f in refusalFlips) {
    diffLines.writeln(
        '<div class="line"><span class="red b">✗ refusalFlip</span> '
        '${_esc(f.promptId)} <span class="muted">(${_esc(f.category)})</span></div>'
        '<div class="line indent">${_esc(f.detail)}</div>');
  }
  diffLines.writeln(
      '<div class="line"><span class="amber b">~ statusChanged</span> '
      '<span class="muted">${statusChanges.length} prompts: every generation '
      'errors (ModelManagerError 1026) despite availability = .available</span></div>');

  return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>underfoot — the on-device model drift observatory</title>
<meta name="description" content="Apple and Google swap the AI models inside your phone with OS updates. underfoot freezes a prompt suite, captures every OS build's answers, and publishes exactly what silently changed.">
<style>
  :root { --bg:#0d1117; --panel:#161b22; --border:#30363d; --fg:#e6edf3;
          --muted:#8b949e; --green:#3fb950; --red:#f85149; --amber:#d29922;
          --accent:#58a6ff; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:var(--bg); color:var(--fg); line-height:1.6;
         font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  main { max-width:880px; margin:0 auto; padding:48px 20px 80px; }
  code, pre, .mono { font-family:"SF Mono",Menlo,Consolas,monospace; }
  h1 { font-size:44px; letter-spacing:-1px; }
  h1 .cursor { color:var(--green); }
  .tagline { font-size:20px; color:var(--muted); margin:10px 0 28px; max-width:640px; }
  .tagline b { color:var(--fg); }
  h2 { font-size:24px; margin:56px 0 16px; letter-spacing:-.3px; }
  p { margin:10px 0; }
  a { color:var(--accent); text-decoration:none; }
  .stats { display:flex; gap:14px; flex-wrap:wrap; margin:26px 0 8px; }
  .stat { background:var(--panel); border:1px solid var(--border); border-radius:10px;
          padding:14px 20px; min-width:150px; }
  .stat .n { font-size:24px; font-weight:700; color:var(--green); }
  .stat .l { color:var(--muted); font-size:13px; }
  .card { background:var(--panel); border:1px solid var(--border); border-radius:12px;
          padding:20px 24px; margin:14px 0; }
  .card h3 { font-size:17px; margin-bottom:6px; }
  .card p { color:var(--muted); font-size:15px; }
  .card p b, .card p code { color:var(--fg); }
  .term { background:#010409; border:1px solid var(--border); border-radius:12px;
          padding:18px 22px; font-size:13.5px; line-height:1.8; overflow-x:auto; }
  .term .line { white-space:pre-wrap; font-family:"SF Mono",Menlo,monospace; }
  .term .indent { padding-left:22px; color:var(--muted); }
  .red { color:var(--red); } .amber { color:var(--amber); }
  .muted { color:var(--muted); } .b { font-weight:700; }
  .ok { color:var(--green); }
  table { border-collapse:collapse; width:100%; margin:14px 0; font-size:14.5px; }
  th, td { text-align:left; padding:9px 12px; border-bottom:1px solid var(--border); }
  th { color:var(--muted); font-weight:600; }
  .badge { border:1px solid; border-radius:20px; padding:1px 10px; font-size:12px;
           font-family:"SF Mono",Menlo,monospace; }
  details.prompt { border:1px solid var(--border); border-radius:10px;
                   margin:8px 0; background:var(--panel); }
  details.prompt summary { cursor:pointer; padding:10px 16px; display:flex;
                           gap:10px; align-items:center; flex-wrap:wrap; }
  details.prompt .cat { color:var(--muted); font-size:12.5px; }
  details.prompt .body { padding:4px 16px 14px; border-top:1px solid var(--border); }
  details.prompt pre { background:#010409; border:1px solid var(--border);
                       border-radius:8px; padding:12px 14px; font-size:13px;
                       white-space:pre-wrap; margin:8px 0; }
  .watch { color:var(--muted); font-size:13px; }
  .det { font-size:12.5px; color:var(--amber); }
  .det.ok-det { color:var(--green); }
  footer { margin-top:64px; border-top:1px solid var(--border); padding-top:22px;
           color:var(--muted); font-size:14.5px; }
  footer b { color:var(--accent); }
</style>
</head>
<body>
<main>
  <h1>underfoot<span class="cursor">▍</span></h1>
  <p class="tagline">Apple and Google swap the AI models inside your phone with
  OS updates — no changelog, no warning. <b>underfoot freezes a prompt suite,
  captures every OS build's answers, and publishes exactly what silently
  changed.</b> Once a build is superseded, its model can never be measured
  again: every capture here is history that cannot be re-taken.</p>

  <div class="stats">
    <div class="stat"><div class="n">${macos.results.length}</div><div class="l">frozen prompts × 5 greedy runs</div></div>
    <div class="stat"><div class="n">2</div><div class="l">OS builds captured so far</div></div>
    <div class="stat"><div class="n">${report.findings.length}</div><div class="l">behavioral differences found between them</div></div>
  </div>

  <h2>Captured builds</h2>
  <table>
    <tr><th>Platform</th><th>OS build</th><th>FoundationModels</th><th>Result</th></tr>
    <tr><td>macOS (M1)</td><td class="mono">${_esc(macos.osVersion)} · ${_esc(macos.osBuild)}</td>
        <td class="mono">${_esc(macos.frameworkBuild ?? '?')}</td>
        <td><span class="ok">$macosOk/${macos.results.length} prompts answered</span> · $macosDeterministic/${macos.results.length} byte-identical across all runs</td></tr>
    <tr><td>iOS simulator (iPhone 17 Pro)</td><td class="mono">${_esc(sim.osVersion)} · ${_esc(sim.osBuild)}</td>
        <td class="mono">${_esc(sim.frameworkBuild ?? '?')}</td>
        <td><span class="red">reports available, fails every generation</span></td></tr>
    <tr><td>iPhone 13 (A15)</td><td class="mono">iOS 26.6 beta</td><td class="mono">—</td>
        <td><span class="muted">below the Apple Intelligence eligibility cliff — model unavailable, permanently</span></td></tr>
  </table>

  <h2>Findings — night one <span class="muted" style="font-size:15px">(July 17, 2026)</span></h2>

  <div class="card"><h3>1 · The baseline is perfectly deterministic — which makes drift measurable</h3>
  <p>All 140 macOS runs succeeded and <b>every prompt returned byte-identical
  output across its 5 greedy runs</b>, including the creative canaries (the
  haiku never varied). Any future change on this platform is the OS's doing,
  not sampling noise.</p></div>

  <div class="card"><h3>2 · "Return only the JSON" returns markdown</h3>
  <p>Every structured-output prompt came back wrapped in <code>&#96;&#96;&#96;json</code>
  fences — deterministically. A naive JSON parse of the response fails today;
  if a future model drops the fences, apps that learned to strip them flip
  behavior instead. Also in the baseline: <b>"reply with exactly one word:
  ready" → <code>Ready.</code></b>, and the Urdu translation prompt returns
  fluent-looking text that is simply wrong — with success status.</p></div>

  <div class="card"><h3>3 · The simulator's availability API cannot be trusted</h3>
  <p>In the iOS ${_esc(sim.osVersion)} simulator on the same
  Apple-Intelligence-enabled Mac, <code>SystemLanguageModel.default.availability</code>
  returns <code>.available</code> — then <b>all 140 generations fail</b> with
  <code>ModelManagerError 1026</code>, reproduced identically on a second run.
  CI that trusts the availability preflight will start suites it cannot finish.</p></div>

  <div class="card"><h3>4 · The guardrail layer drifts independently of the model</h3>
  <p>Framework ${_esc(sim.frameworkBuild ?? '1.1.7')} rejected the benign
  <b>city-council meeting summarization</b> prompt as
  <i>"May contain unsafe content"</i> — the exact prompt framework
  ${_esc(macos.frameworkBuild ?? '1.5.2')} passes 5/5. The input safety
  classifier fired even though the model itself never executed: refusal
  behavior is a property of the <b>OS build</b>, not just the model.</p></div>

  <h2>The diff, as the tool reports it</h2>
  <p class="muted" style="font-size:14px">Output of <code>underfoot_diff</code>
  comparing the two captures — refusal flips always rank first:</p>
  <div class="term">
    <div class="line"><span class="muted">\$ dart diff/bin/underfoot_diff.dart captures/apple/25F80/… captures/apple/23D8133/…</span></div>
    <div class="line">underfoot: "underfoot-core" v1 — ${_esc(macos.label)} → ${_esc(sim.label)}</div>
    <div class="line">  ${report.findings.length} drifted · ${report.stableCount} stable</div>
${diffLines.toString().split('\n').map((l) => '    $l').join('\n')}
  </div>

  <h2>The baseline, prompt by prompt</h2>
  <p class="muted" style="font-size:14px">macOS ${_esc(macos.osVersion)}
  (${_esc(macos.osBuild)}), framework ${_esc(macos.frameworkBuild ?? '?')} —
  ${categories.length} categories. Every output below is a real, committed
  capture; click to expand.</p>
  $promptRows

  <h2>Method</h2>
  <div class="card"><p>
  <b>Frozen suite.</b> 28 prompts, versioned and hashed — captures are only
  comparable within one exact suite version (name + version + SHA-256 all
  enforced by the diff tool).<br>
  <b>Deterministic protocol.</b> Greedy sampling, fresh session per run,
  5 runs per prompt (so determinism itself is measured), one unrecorded
  warmup, sequential execution, thermal state recorded.<br>
  <b>Honest labeling.</b> Simulator captures are marked as such — the model
  executes via the host Mac. Every outcome is classified:
  ok / refusal / unsupported-language / context-exceeded / error.<br>
  <b>Open data.</b> Every capture is a committed JSON file with full outputs —
  check the math, rerun the diff, cite the build numbers.
  </p></div>

  <footer>
    <p>underfoot is part of the testing &amp; safety layer for on-device AI:
    <b>golden_lens</b> · <b>llm_replay_eval</b> · <b>redact</b> · <b>vouch</b> ·
    <b>underfoot</b></p>
    <p>Built by Muhammad Umer — captures, harnesses, and the diff engine are
    open source.</p>
  </footer>
</main>
</body>
</html>
''';
}
