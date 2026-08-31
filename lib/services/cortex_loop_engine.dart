// lib/services/cortex_loop_engine.dart
//
// CortexLoopEngine
// ----------------------------------------------------------------------------
// Orchestrates the autonomous "Resolve Dependencies -> Lint -> Test -> Build"
// pipeline. Each stage runs through TerminalRunnerService; on failure the
// engine extracts an error signature, calls SearchService for repair
// context, and (optionally) hands that context to a pluggable "repair"
// callback (e.g. your model-completion call) before retrying, up to a
// configurable max-attempt budget. All attempts are scored and recorded for
// the Analytics screen.
// ----------------------------------------------------------------------------

import 'dart:async';
import 'package:flutter/foundation.dart';

import 'terminal_runner_service.dart';
import 'search_service.dart';

enum CortexStage { resolveDependencies, lint, test, build }

extension CortexStageX on CortexStage {
  String get label => switch (this) {
        CortexStage.resolveDependencies => 'Resolve Dependencies',
        CortexStage.lint => 'Lint',
        CortexStage.test => 'Test',
        CortexStage.build => 'Build',
      };
}

/// A single scored attempt at running the full pipeline (or one stage of it).
class LoopAttempt {
  final int attemptNumber;
  final CortexStage stage;
  final bool success;
  final int score; // 0-100 evaluation score
  final String summary;
  final DateTime timestamp;
  final bool usedWebRepair;

  LoopAttempt({
    required this.attemptNumber,
    required this.stage,
    required this.success,
    required this.score,
    required this.summary,
    required this.usedWebRepair,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Callback signature for a pluggable "repair" step — typically a call out
/// to your LLM with the failing stderr + web context, returning true if it
/// believes it applied a fix and the stage should be retried.
typedef RepairCallback = Future<bool> Function({
  required CortexStage stage,
  required String stderrOutput,
  required String webRepairContext,
});

class CortexLoopEngine extends ChangeNotifier {
  CortexLoopEngine({
    required this.projectPath,
    this.maxAttemptsPerStage = 3,
    this.stageTimeout = const Duration(minutes: 5),
    this.useNpm = false,
    RepairCallback? onRepairNeeded,
  }) : _onRepairNeeded = onRepairNeeded;

  final String projectPath;
  final int maxAttemptsPerStage;
  final Duration stageTimeout;
  final bool useNpm; // false => flutter/dart toolchain, true => npm toolchain
  final RepairCallback? _onRepairNeeded;

  final TerminalRunnerService _runner = TerminalRunnerService.instance;
  final SearchService _search = SearchService.instance;

  final List<LoopAttempt> attempts = [];
  bool isRunning = false;
  int automatedRepairCount = 0;
  int? initialScore;
  int? finalScore;

  int get testPassCount => attempts.where((a) => a.stage == CortexStage.test && a.success).length;
  int get testTotalCount => attempts.where((a) => a.stage == CortexStage.test).length;
  double get testPassRate => testTotalCount == 0 ? 0 : testPassCount / testTotalCount;

  /// Runs the full 4-stage pipeline autonomously, stage by stage. Stops
  /// early if a stage exhausts its attempt budget without succeeding.
  Future<bool> runFullPipeline() async {
    if (isRunning) return false;
    isRunning = true;
    attempts.clear();
    automatedRepairCount = 0;
    initialScore = null;
    finalScore = null;
    notifyListeners();

    bool allStagesPassed = true;
    for (final stage in CortexStage.values) {
      final passed = await _runStageWithRepairLoop(stage);
      if (!passed) {
        allStagesPassed = false;
        break; // Don't cascade into later stages on a broken build.
      }
    }

    isRunning = false;
    finalScore = attempts.isEmpty ? 0 : attempts.last.score;
    notifyListeners();
    return allStagesPassed;
  }

  Future<bool> _runStageWithRepairLoop(CortexStage stage) async {
    for (int attemptNum = 1; attemptNum <= maxAttemptsPerStage; attemptNum++) {
      final run = await _executeStage(stage);
      final score = _scoreRun(run);
      initialScore ??= score;

      final attempt = LoopAttempt(
        attemptNumber: attempts.length + 1,
        stage: stage,
        success: run.status == CommandStatus.success,
        score: score,
        summary: run.status == CommandStatus.success
            ? '${stage.label} succeeded on attempt $attemptNum.'
            : '${stage.label} failed (exit ${run.exitCode}) on attempt $attemptNum.',
        usedWebRepair: false,
      );
      attempts.add(attempt);
      notifyListeners();

      if (run.status == CommandStatus.success) {
        return true;
      }

      // Failure path: attempt an automated web-search-assisted repair,
      // unless we're out of budget.
      if (attemptNum == maxAttemptsPerStage) {
        return false;
      }

      final stderrOutput = run.stderrLines.join('\n');
      final query = ErrorSignatureDetector.extractQueryFromStderr(stderrOutput);
      String webContext = '';
      bool usedWebRepair = false;

      if (query != null) {
        final results = await _search.search(query);
        webContext = _search.buildRepairContext(results);
        if (results.isNotEmpty) {
          usedWebRepair = true;
        }
      }

      if (_onRepairNeeded != null) {
        final repaired = await _onRepairNeeded(
          stage: stage,
          stderrOutput: stderrOutput,
          webRepairContext: webContext,
        );
        if (repaired) {
          automatedRepairCount++;
          attempts.add(LoopAttempt(
            attemptNumber: attempts.length + 1,
            stage: stage,
            success: false,
            score: score,
            summary: 'Applied automated repair for ${stage.label} '
                '(web context: ${usedWebRepair ? "yes" : "no"}). Retrying...',
            usedWebRepair: usedWebRepair,
          ));
          notifyListeners();
        }
      }
      // Loop continues to the next attempt regardless — the retry itself
      // is what validates whether the repair worked.
    }
    return false;
  }

  Future<CommandRun> _executeStage(CortexStage stage) {
    switch (stage) {
      case CortexStage.resolveDependencies:
        return useNpm
            ? _runner.runCommand(
                executable: 'npm',
                arguments: ['install'],
                workingDirectory: projectPath,
                timeout: stageTimeout,
              )
            : _runner.runCommand(
                executable: 'flutter',
                arguments: ['pub', 'get'],
                workingDirectory: projectPath,
                timeout: stageTimeout,
              );
      case CortexStage.lint:
        return _runner.runCommand(
          executable: 'flutter',
          arguments: ['analyze'],
          workingDirectory: projectPath,
          timeout: stageTimeout,
        );
      case CortexStage.test:
        return _runner.runCommand(
          executable: 'flutter',
          arguments: ['test'],
          workingDirectory: projectPath,
          timeout: stageTimeout,
        );
      case CortexStage.build:
        return _runner.runCommand(
          executable: 'flutter',
          arguments: ['build', 'apk', '--release'],
          workingDirectory: projectPath,
          timeout: Duration(minutes: stageTimeout.inMinutes.clamp(10, 30)),
        );
    }
  }

  /// Simple deterministic 0-100 evaluation score. Weighted so that
  /// later stages (test/build) carry more signal than earlier ones,
  /// and successful stages start high with penalties for stderr volume.
  int _scoreRun(CommandRun run) {
    if (run.status != CommandStatus.success) {
      // Partial credit for producing *some* usable stdout/no crash-loop.
      final base = 20;
      final penalty = (run.stderrLines.length).clamp(0, 20);
      return (base - penalty).clamp(0, 100);
    }
    final stageWeight = switch (run.executable) {
      'npm' => 70,
      _ => 85,
    };
    final warningPenalty = run.stdoutLines
        .where((l) => l.toLowerCase().contains('warning'))
        .length
        .clamp(0, 15);
    return (stageWeight - warningPenalty).clamp(0, 100);
  }

  Future<void> cancel() async {
    await _runner.cancelAll();
    isRunning = false;
    notifyListeners();
  }
}
