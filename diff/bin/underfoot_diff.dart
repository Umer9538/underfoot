import 'dart:convert';
import 'dart:io';

import 'package:underfoot_diff/underfoot_diff.dart';

void main(List<String> arguments) {
  final json = arguments.contains('--json');
  final paths = [
    for (final a in arguments)
      if (a != '--json') a
  ];
  if (paths.length != 2) {
    stderr.writeln(
        'usage: dart run underfoot_diff <baseline.capture.json> <current.capture.json> [--json]');
    exitCode = 64;
    return;
  }
  final Capture baseline;
  final Capture current;
  try {
    baseline = Capture.parse(File(paths[0]).readAsStringSync());
    current = Capture.parse(File(paths[1]).readAsStringSync());
  } on FileSystemException catch (e) {
    stderr.writeln('cannot read capture: ${e.path}: ${e.osError?.message}');
    exitCode = 66;
    return;
  } on CaptureFormatException catch (e) {
    stderr.writeln('$e');
    exitCode = 65;
    return;
  }

  final DriftReport report;
  try {
    report = compareCaptures(baseline, current);
  } on ArgumentError catch (e) {
    stderr.writeln('not comparable: ${e.message}');
    exitCode = 64;
    return;
  }

  stdout.write(json
      ? '${const JsonEncoder.withIndent('  ').convert(report.toJson())}\n'
      : report.summary());
  if (report.hasDrift) exitCode = 1;
}
