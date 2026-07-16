import 'dart:convert';

import 'package:underfoot_diff/underfoot_diff.dart';
import 'package:test/test.dart';

/// Builds a minimal capture JSON with the given per-prompt runs.
/// Runs are (status, output) pairs; output is ignored for non-ok statuses.
Map<String, dynamic> captureJson({
  Map<String, List<(String, String?)>> prompts = const {},
  String suite = 'underfoot-core',
  int suiteVersion = 1,
  String suiteSha256 = 'abc123',
  String osBuild = '25F80',
  String osVersion = '26.5.1',
}) =>
    {
      'formatVersion': 1,
      'tool': 'underfoot',
      'suite': suite,
      'suiteVersion': suiteVersion,
      'suiteSha256': suiteSha256,
      'platform': {'osVersion': osVersion, 'osBuild': osBuild},
      'model': {'family': 'apple-foundation-models', 'frameworkBuild': '1.5.2'},
      'capturedAt': '2026-07-17T00:00:00Z',
      'results': [
        for (final entry in prompts.entries)
          {
            'promptId': entry.key,
            'category': 'test',
            'runs': [
              for (final (status, output) in entry.value)
                {'status': status, if (status == 'ok') 'output': output},
            ],
          },
      ],
    };

Capture capture({
  Map<String, List<(String, String?)>> prompts = const {},
  String suite = 'underfoot-core',
  int suiteVersion = 1,
  String suiteSha256 = 'abc123',
  String osBuild = '25F80',
}) =>
    Capture.fromJson(captureJson(
      prompts: prompts,
      suite: suite,
      suiteVersion: suiteVersion,
      suiteSha256: suiteSha256,
      osBuild: osBuild,
    ));

List<(String, String?)> okRuns(String output, [int n = 5]) =>
    [for (var i = 0; i < n; i++) ('ok', output)];

List<(String, String?)> refusalRuns([int n = 5]) =>
    [for (var i = 0; i < n; i++) ('refusal', null)];

void main() {
  test('identical captures produce zero findings', () {
    final a = capture(prompts: {'p1': okRuns('A'), 'p2': refusalRuns()});
    final b = capture(prompts: {'p1': okRuns('A'), 'p2': refusalRuns()});
    final report = compareCaptures(a, b);
    expect(report.hasDrift, isFalse);
    expect(report.findings, isEmpty);
    expect(report.stableCount, 2);
  });

  test('a prompt that starts refusing is a refusalFlip, worst-first', () {
    final a = capture(prompts: {'health': okRuns('Drink 8 glasses.')});
    final b = capture(prompts: {'health': refusalRuns()});
    final report = compareCaptures(a, b);
    final finding = report.findings.single;
    expect(finding.kind, DriftKind.refusalFlip);
    expect(finding.detail, contains('now refuses'));
    expect(finding.baselineOutputs, ['Drink 8 glasses.']);
  });

  test('a prompt that stops refusing is also a refusalFlip', () {
    final a = capture(prompts: {'health': refusalRuns()});
    final b = capture(prompts: {'health': okRuns('Drink 8 glasses.')});
    final report = compareCaptures(a, b);
    expect(report.findings.single.kind, DriftKind.refusalFlip);
    expect(report.findings.single.detail, contains('now answers'));
  });

  test('ok -> error without refusal is statusChanged', () {
    final a = capture(prompts: {'p': okRuns('A')});
    final b = capture(prompts: {
      'p': [
        ('ok', 'A'),
        ('ok', 'A'),
        ('ok', 'A'),
        ('ok', 'A'),
        ('error', null)
      ],
    });
    final report = compareCaptures(a, b);
    expect(report.findings.single.kind, DriftKind.statusChanged);
  });

  test('same statuses but different output is outputChanged', () {
    final a = capture(prompts: {'p': okRuns('{"a":1}')});
    final b = capture(prompts: {'p': okRuns('Sure! The value of a is 1.')});
    final report = compareCaptures(a, b);
    final finding = report.findings.single;
    expect(finding.kind, DriftKind.outputChanged);
    expect(finding.baselineOutputs, ['{"a":1}']);
    expect(finding.currentOutputs, ['Sure! The value of a is 1.']);
  });

  test('determinism loss shows as outputChanged with distinct-output count',
      () {
    final a = capture(prompts: {'p': okRuns('A')});
    final b = capture(prompts: {
      'p': [('ok', 'A'), ('ok', 'B'), ('ok', 'A'), ('ok', 'B'), ('ok', 'C')],
    });
    final report = compareCaptures(a, b);
    expect(report.findings.single.kind, DriftKind.outputChanged);
    expect(report.findings.single.detail, contains('3 distinct outputs'));
  });

  test('removed and added prompts are tracked, never silently dropped', () {
    final a = capture(prompts: {'old': okRuns('A'), 'both': okRuns('B')});
    final b = capture(prompts: {'new': okRuns('C'), 'both': okRuns('B')});
    final report = compareCaptures(a, b);
    expect(report.ofKind(DriftKind.promptRemoved).single.promptId, 'old');
    expect(report.ofKind(DriftKind.promptAdded).single.promptId, 'new');
    expect(report.stableCount, 1);
  });

  test('findings sort worst-first: refusalFlip before outputChanged', () {
    final a = capture(prompts: {
      'z-output': okRuns('A'),
      'a-refusal': okRuns('B'),
    });
    final b = capture(prompts: {
      'z-output': okRuns('changed'),
      'a-refusal': refusalRuns(),
    });
    final report = compareCaptures(a, b);
    expect(report.findings.first.kind, DriftKind.refusalFlip);
    expect(report.findings.last.kind, DriftKind.outputChanged);
  });

  group('comparability guards', () {
    test('different suites throw', () {
      final a = capture(suite: 'core');
      final b = capture(suite: 'other');
      expect(() => compareCaptures(a, b), throwsArgumentError);
    });

    test('same suite name but different prompt-file hash throws', () {
      final a = capture(suiteSha256: 'aaa');
      final b = capture(suiteSha256: 'bbb');
      expect(() => compareCaptures(a, b), throwsArgumentError);
    });

    test('different suite versions throw', () {
      final a = capture(suiteVersion: 1);
      final b = Capture.fromJson(captureJson(suiteVersion: 2));
      expect(() => compareCaptures(a, b), throwsArgumentError);
    });
  });

  group('strict parsing', () {
    test('invalid JSON throws CaptureFormatException', () {
      expect(() => Capture.parse('{not json'),
          throwsA(isA<CaptureFormatException>()));
    });

    test('duplicate promptId throws', () {
      final json = captureJson(prompts: {'p': okRuns('A')});
      (json['results'] as List).add((json['results'] as List).first);
      expect(
          () => Capture.fromJson(json), throwsA(isA<CaptureFormatException>()));
    });

    test('run without status throws', () {
      final json = captureJson(prompts: {'p': okRuns('A')});
      (json['results'] as List).first['runs'] = <Map<String, dynamic>>[{}];
      expect(
          () => Capture.fromJson(json), throwsA(isA<CaptureFormatException>()));
    });

    test('empty runs list throws', () {
      final json = captureJson(prompts: {'p': okRuns('A')});
      (json['results'] as List).first['runs'] = <Object>[];
      expect(
          () => Capture.fromJson(json), throwsA(isA<CaptureFormatException>()));
    });
  });

  test('toJson payload carries counts and findings for machines', () {
    final a = capture(prompts: {'p1': okRuns('A'), 'p2': okRuns('B')});
    final b = capture(prompts: {'p1': refusalRuns(), 'p2': okRuns('B')});
    final json = compareCaptures(a, b).toJson();
    expect(json['tool'], 'underfoot');
    expect(json['formatVersion'], 1);
    final counts = json['counts'] as Map<String, dynamic>;
    expect(counts['refusalFlip'], 1);
    expect(counts['stable'], 1);
    expect(counts['total'], 2);
    expect(jsonDecode(jsonEncode(json)), isA<Map<String, dynamic>>());
  });

  test('summary is human-readable and names the builds', () {
    final a = capture(prompts: {'p': okRuns('A')});
    final b = Capture.fromJson(captureJson(
      prompts: {'p': okRuns('B')},
      osBuild: '26A100',
      osVersion: '27.0',
    ));
    final summary = compareCaptures(a, b).summary();
    expect(summary, contains('25F80'));
    expect(summary, contains('26A100'));
    expect(summary, contains('[outputChanged] p'));
  });
}
