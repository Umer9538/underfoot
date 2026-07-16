/// Compares two underfoot captures of the same suite and reports which
/// prompts changed behavior between them — refusal flips first, then status
/// changes, output changes, and coverage changes. The rules mirror vouch's
/// diff semantics: movement, not state; identical captures produce zero
/// findings; malformed captures throw instead of shrinking coverage.
library;

import 'dart:convert';

/// Thrown when a capture file is structurally invalid. A capture that cannot
/// be fully parsed must never be silently partially compared.
class CaptureFormatException implements Exception {
  CaptureFormatException(this.message);
  final String message;
  @override
  String toString() => 'CaptureFormatException: $message';
}

class RunResult {
  RunResult({required this.status, this.output});

  factory RunResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    if (status is! String || status.isEmpty) {
      throw CaptureFormatException('run is missing a status');
    }
    final output = json['output'];
    if (output != null && output is! String) {
      throw CaptureFormatException('run output must be a string when present');
    }
    return RunResult(status: status, output: output as String?);
  }

  final String status;
  final String? output;
}

class PromptCapture {
  PromptCapture({
    required this.promptId,
    required this.category,
    required this.runs,
  });

  factory PromptCapture.fromJson(Map<String, dynamic> json) {
    final promptId = json['promptId'];
    if (promptId is! String || promptId.isEmpty) {
      throw CaptureFormatException('result is missing promptId');
    }
    final category = json['category'];
    if (category is! String || category.isEmpty) {
      throw CaptureFormatException('result "$promptId" is missing category');
    }
    final runsJson = json['runs'];
    if (runsJson is! List || runsJson.isEmpty) {
      throw CaptureFormatException('result "$promptId" has no runs');
    }
    return PromptCapture(
      promptId: promptId,
      category: category,
      runs: [
        for (final run in runsJson)
          if (run is Map<String, dynamic>)
            RunResult.fromJson(run)
          else
            throw CaptureFormatException(
                'result "$promptId" contains a non-object run'),
      ],
    );
  }

  final String promptId;
  final String category;
  final List<RunResult> runs;

  /// Sorted multiset of run statuses, e.g. `[ok, ok, ok, refusal, refusal]`.
  List<String> get statusProfile =>
      [for (final run in runs) run.status]..sort();

  /// Distinct successful outputs across runs.
  Set<String> get outputSet => {
        for (final run in runs)
          if (run.status == 'ok' && run.output != null) run.output!,
      };

  bool get hasRefusal => runs.any((r) => r.status == 'refusal');
}

class Capture {
  Capture({
    required this.suite,
    required this.suiteVersion,
    required this.suiteSha256,
    required this.osVersion,
    required this.osBuild,
    required this.frameworkBuild,
    required this.capturedAt,
    required this.results,
  });

  factory Capture.fromJson(Map<String, dynamic> json) {
    final suite = json['suite'];
    final suiteVersion = json['suiteVersion'];
    final suiteSha = json['suiteSha256'];
    if (suite is! String || suiteVersion is! int || suiteSha is! String) {
      throw CaptureFormatException(
          'capture is missing suite/suiteVersion/suiteSha256');
    }
    final platform = json['platform'];
    if (platform is! Map<String, dynamic>) {
      throw CaptureFormatException('capture is missing platform metadata');
    }
    final resultsJson = json['results'];
    if (resultsJson is! List) {
      throw CaptureFormatException('capture is missing results');
    }
    final results = <String, PromptCapture>{};
    for (final entry in resultsJson) {
      if (entry is! Map<String, dynamic>) {
        throw CaptureFormatException('results contains a non-object entry');
      }
      final parsed = PromptCapture.fromJson(entry);
      if (results.containsKey(parsed.promptId)) {
        throw CaptureFormatException(
            'duplicate promptId "${parsed.promptId}" in capture');
      }
      results[parsed.promptId] = parsed;
    }
    final model = json['model'];
    return Capture(
      suite: suite,
      suiteVersion: suiteVersion,
      suiteSha256: suiteSha,
      osVersion: platform['osVersion'] as String? ?? 'unknown',
      osBuild: platform['osBuild'] as String? ?? 'unknown',
      frameworkBuild: model is Map<String, dynamic>
          ? model['frameworkBuild'] as String?
          : null,
      capturedAt: json['capturedAt'] as String? ?? 'unknown',
      results: results,
    );
  }

  static Capture parse(String jsonText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw CaptureFormatException('capture is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw CaptureFormatException('capture root must be an object');
    }
    return Capture.fromJson(decoded);
  }

  final String suite;
  final int suiteVersion;
  final String suiteSha256;
  final String osVersion;
  final String osBuild;
  final String? frameworkBuild;
  final String capturedAt;
  final Map<String, PromptCapture> results;

  String get label =>
      '$osVersion ($osBuild${frameworkBuild == null ? '' : ', fm $frameworkBuild'})';
}

/// Ordered worst-first; report findings sort by this order.
enum DriftKind {
  refusalFlip,
  statusChanged,
  outputChanged,
  promptRemoved,
  promptAdded,
}

class DriftFinding {
  DriftFinding({
    required this.kind,
    required this.promptId,
    required this.category,
    required this.detail,
    this.baselineStatuses,
    this.currentStatuses,
    this.baselineOutputs,
    this.currentOutputs,
  });

  final DriftKind kind;
  final String promptId;
  final String category;
  final String detail;
  final List<String>? baselineStatuses;
  final List<String>? currentStatuses;
  final List<String>? baselineOutputs;
  final List<String>? currentOutputs;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'promptId': promptId,
        'category': category,
        'detail': detail,
        if (baselineStatuses != null) 'baselineStatuses': baselineStatuses,
        if (currentStatuses != null) 'currentStatuses': currentStatuses,
        if (baselineOutputs != null) 'baselineOutputs': baselineOutputs,
        if (currentOutputs != null) 'currentOutputs': currentOutputs,
      };
}

class DriftReport {
  DriftReport({
    required this.suite,
    required this.suiteVersion,
    required this.baseline,
    required this.current,
    required this.findings,
    required this.stableCount,
  });

  final String suite;
  final int suiteVersion;
  final Capture baseline;
  final Capture current;
  final List<DriftFinding> findings;
  final int stableCount;

  bool get hasDrift => findings.isNotEmpty;

  List<DriftFinding> ofKind(DriftKind kind) => [
        for (final f in findings)
          if (f.kind == kind) f
      ];

  Map<String, dynamic> toJson() => {
        'tool': 'underfoot',
        'formatVersion': 1,
        'suite': suite,
        'suiteVersion': suiteVersion,
        'baseline': {
          'osVersion': baseline.osVersion,
          'osBuild': baseline.osBuild,
          'frameworkBuild': baseline.frameworkBuild,
          'capturedAt': baseline.capturedAt,
        },
        'current': {
          'osVersion': current.osVersion,
          'osBuild': current.osBuild,
          'frameworkBuild': current.frameworkBuild,
          'capturedAt': current.capturedAt,
        },
        'counts': {
          for (final kind in DriftKind.values) kind.name: ofKind(kind).length,
          'stable': stableCount,
          'total': findings.length + stableCount,
        },
        'findings': [for (final f in findings) f.toJson()],
      };

  String summary() {
    final buffer = StringBuffer()
      ..writeln('underfoot: "$suite" v$suiteVersion — '
          '${baseline.label} → ${current.label}')
      ..writeln(hasDrift
          ? '  ${findings.length} drifted · $stableCount stable'
          : '  no drift · $stableCount stable');
    for (final finding in findings) {
      buffer.writeln('  [${finding.kind.name}] ${finding.promptId} '
          '(${finding.category}): ${finding.detail}');
    }
    return buffer.toString();
  }
}

String _describeOutputs(Set<String> outputs) {
  if (outputs.isEmpty) return '(no successful outputs)';
  final first = outputs.first;
  final snip = first.length > 60 ? '${first.substring(0, 60)}…' : first;
  return outputs.length == 1
      ? '"${snip.replaceAll('\n', ' ')}"'
      : '${outputs.length} distinct outputs';
}

/// Compares two captures of the same suite version. Throws [ArgumentError]
/// when the captures are not comparable (different suite, version, or prompt
/// file hash) — cross-suite diffs are meaningless and must never be produced.
DriftReport compareCaptures(Capture baseline, Capture current) {
  if (baseline.suite != current.suite) {
    throw ArgumentError('cannot compare different suites: '
        '"${baseline.suite}" vs "${current.suite}"');
  }
  if (baseline.suiteVersion != current.suiteVersion ||
      baseline.suiteSha256 != current.suiteSha256) {
    throw ArgumentError(
        'captures use different versions of suite "${baseline.suite}" — '
        'captures are only comparable within one exact suite version');
  }

  final findings = <DriftFinding>[];
  var stable = 0;

  for (final entry in baseline.results.entries) {
    final before = entry.value;
    final after = current.results[entry.key];
    if (after == null) {
      findings.add(DriftFinding(
        kind: DriftKind.promptRemoved,
        promptId: before.promptId,
        category: before.category,
        detail: 'prompt present in baseline capture but missing from current',
      ));
      continue;
    }

    final refusalFlipped = before.hasRefusal != after.hasRefusal;
    final statusChanged =
        !_listEquals(before.statusProfile, after.statusProfile);
    final outputChanged = !_setEquals(before.outputSet, after.outputSet);

    if (refusalFlipped) {
      findings.add(DriftFinding(
        kind: DriftKind.refusalFlip,
        promptId: before.promptId,
        category: before.category,
        detail: after.hasRefusal
            ? 'now refuses (was answering): '
                '${_describeOutputs(before.outputSet)} → guardrail refusal'
            : 'now answers (was refusing): '
                'guardrail refusal → ${_describeOutputs(after.outputSet)}',
        baselineStatuses: before.statusProfile,
        currentStatuses: after.statusProfile,
        baselineOutputs: [...before.outputSet],
        currentOutputs: [...after.outputSet],
      ));
    } else if (statusChanged) {
      findings.add(DriftFinding(
        kind: DriftKind.statusChanged,
        promptId: before.promptId,
        category: before.category,
        detail: 'run statuses changed: '
            '${before.statusProfile} → ${after.statusProfile}',
        baselineStatuses: before.statusProfile,
        currentStatuses: after.statusProfile,
        baselineOutputs: [...before.outputSet],
        currentOutputs: [...after.outputSet],
      ));
    } else if (outputChanged) {
      findings.add(DriftFinding(
        kind: DriftKind.outputChanged,
        promptId: before.promptId,
        category: before.category,
        detail: '${_describeOutputs(before.outputSet)} → '
            '${_describeOutputs(after.outputSet)}',
        baselineOutputs: [...before.outputSet],
        currentOutputs: [...after.outputSet],
      ));
    } else {
      stable++;
    }
  }

  for (final entry in current.results.entries) {
    if (!baseline.results.containsKey(entry.key)) {
      findings.add(DriftFinding(
        kind: DriftKind.promptAdded,
        promptId: entry.value.promptId,
        category: entry.value.category,
        detail: 'prompt present in current capture but not in baseline',
      ));
    }
  }

  findings.sort((a, b) {
    final byKind = a.kind.index.compareTo(b.kind.index);
    return byKind != 0 ? byKind : a.promptId.compareTo(b.promptId);
  });

  return DriftReport(
    suite: baseline.suite,
    suiteVersion: baseline.suiteVersion,
    baseline: baseline,
    current: current,
    findings: findings,
    stableCount: stable,
  );
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);
