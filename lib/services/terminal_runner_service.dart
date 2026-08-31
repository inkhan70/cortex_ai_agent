// lib/services/terminal_runner_service.dart
//
// TerminalRunnerService
// ----------------------------------------------------------------------------
// Non-interactive process execution engine for the Cortex Loop.
//
// IMPORTANT PLATFORM NOTE:
// `dart:io` Process APIs only run on Flutter's Desktop/Mobile "host-capable"
// targets (Android via a companion daemon/shell, iOS is sandboxed and will
// NOT allow arbitrary shell execution, Web has no dart:io at all). On stock
// Android/iOS, apps cannot invoke `flutter`, `npm`, etc. against arbitrary
// project directories the way a desktop CI runner can — there is no shell
// environment with those toolchains installed. This service is written to
// run correctly on Flutter Desktop (Linux/macOS/Windows) or against a
// companion build-agent process reachable on the LAN. On mobile it will
// gracefully report "unsupported platform" per command rather than silently
// failing. Document this clearly to end users of the app.
//
// This class provides:
//   - Fire-and-forget + awaited background execution via Process.start()
//   - Real-time stdout/stderr stream capture
//   - Per-process timeout enforcement with guaranteed cleanup (kill)
//   - Exit code evaluation
//   - Cancellation support (cancel a running or queued command)
//   - A broadcast stream of TerminalLogEvent for UI + engine consumers
// ----------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The kind of stream a log line originated from.
enum LogStreamType { stdout, stderr, system }

/// The lifecycle status of a tracked command.
enum CommandStatus { queued, running, success, failed, timedOut, cancelled }

/// A single line of output emitted by a running command.
class TerminalLogEvent {
  final String commandId;
  final String line;
  final LogStreamType type;
  final DateTime timestamp;

  TerminalLogEvent({
    required this.commandId,
    required this.line,
    required this.type,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Represents the full record of a command run, updated as it progresses.
class CommandRun {
  final String id;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  CommandStatus status;
  int? exitCode;
  final List<String> stdoutLines = [];
  final List<String> stderrLines = [];
  final DateTime startedAt;
  DateTime? finishedAt;
  Process? _process;

  CommandRun({
    required this.id,
    required this.executable,
    required this.arguments,
    this.workingDirectory,
    this.status = CommandStatus.queued,
  }) : startedAt = DateTime.now();

  String get fullCommand => '$executable ${arguments.join(' ')}';

  bool get isTerminal =>
      status == CommandStatus.success ||
      status == CommandStatus.failed ||
      status == CommandStatus.timedOut ||
      status == CommandStatus.cancelled;

  String get combinedOutput =>
      [...stdoutLines, ...stderrLines].join('\n');
}

/// Thrown when a command exceeds its allotted timeout.
class ProcessTimeoutException implements Exception {
  final String commandId;
  final Duration timeout;
  ProcessTimeoutException(this.commandId, this.timeout);
  @override
  String toString() =>
      'ProcessTimeoutException: command $commandId exceeded ${timeout.inSeconds}s';
}

class TerminalRunnerService {
  TerminalRunnerService._internal();
  static final TerminalRunnerService instance =
      TerminalRunnerService._internal();

  final Map<String, CommandRun> _runs = {};
  final StreamController<TerminalLogEvent> _logController =
      StreamController<TerminalLogEvent>.broadcast();
  final StreamController<CommandRun> _statusController =
      StreamController<CommandRun>.broadcast();

  /// Live stream of individual log lines — consumed by TerminalScreen.
  Stream<TerminalLogEvent> get logStream => _logController.stream;

  /// Live stream of command status transitions — consumed by CortexLoopEngine.
  Stream<CommandRun> get statusStream => _statusController.stream;

  CommandRun? getRun(String id) => _runs[id];

  List<CommandRun> get history => _runs.values.toList(growable: false);

  /// True on platforms where dart:io Process execution is actually available.
  bool get isProcessExecutionSupported =>
      !kIsWebPlatform && (Platform.isLinux || Platform.isMacOS || Platform.isWindows || Platform.isAndroid);

  static bool get kIsWebPlatform {
    // identical(0, 0.0) is false on web (dart2js/dartdevc num representation)
    return identical(0, 0.0);
  }

  /// Runs a command to completion (non-interactively) with a timeout,
  /// streaming stdout/stderr as it becomes available. Returns the final
  /// [CommandRun] record. Never throws for a failing exit code — only for
  /// infrastructure problems (missing executable, timeout, cancellation).
  Future<CommandRun> runCommand({
    required String executable,
    List<String> arguments = const [],
    String? workingDirectory,
    Duration timeout = const Duration(minutes: 5),
    Map<String, String>? environment,
    String? commandId,
  }) async {
    final id = commandId ?? _generateId();
    final run = CommandRun(
      id: id,
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
    );
    _runs[id] = run;

    if (!isProcessExecutionSupported) {
      run.status = CommandStatus.failed;
      run.finishedAt = DateTime.now();
      _emitLog(id, 'Process execution is not supported on this platform.',
          LogStreamType.system);
      _statusController.add(run);
      return run;
    }

    Timer? timeoutTimer;
    final completer = Completer<CommandRun>();

    try {
      run.status = CommandStatus.running;
      _statusController.add(run);
      _emitLog(id, '\$ ${run.fullCommand}', LogStreamType.system);

      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: true,
        mode: ProcessStartMode.normal,
      );
      run._process = process;

      // Enforce timeout: kill process tree and mark timedOut if exceeded.
      timeoutTimer = Timer(timeout, () {
        if (!run.isTerminal) {
          _emitLog(id, '⏱ Timeout exceeded (${timeout.inSeconds}s) — killing process.',
              LogStreamType.system);
          _killProcessSafely(process);
          run.status = CommandStatus.timedOut;
          run.finishedAt = DateTime.now();
          _statusController.add(run);
          if (!completer.isCompleted) completer.complete(run);
        }
      });

      final stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        run.stdoutLines.add(line);
        _emitLog(id, line, LogStreamType.stdout);
      });

      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        run.stderrLines.add(line);
        _emitLog(id, line, LogStreamType.stderr);
      });

      final exitCode = await process.exitCode;

      // Ensure stream buffers are flushed before finalizing.
      await Future.wait([stdoutSub.asFuture<void>(), stderrSub.asFuture<void>()])
          .catchError((_) => <void>[]);
      await stdoutSub.cancel();
      await stderrSub.cancel();

      if (!run.isTerminal) {
        run.exitCode = exitCode;
        run.status = exitCode == 0 ? CommandStatus.success : CommandStatus.failed;
        run.finishedAt = DateTime.now();
        _emitLog(
          id,
          exitCode == 0
              ? '✔ Completed successfully (exit code 0).'
              : '✘ Failed (exit code $exitCode).',
          LogStreamType.system,
        );
        _statusController.add(run);
      }

      if (!completer.isCompleted) completer.complete(run);
    } on ProcessException catch (e) {
      run.status = CommandStatus.failed;
      run.finishedAt = DateTime.now();
      _emitLog(id, 'Process failed to start: ${e.message}', LogStreamType.system);
      _statusController.add(run);
      if (!completer.isCompleted) completer.complete(run);
    } catch (e) {
      run.status = CommandStatus.failed;
      run.finishedAt = DateTime.now();
      _emitLog(id, 'Unexpected error: $e', LogStreamType.system);
      _statusController.add(run);
      if (!completer.isCompleted) completer.complete(run);
    } finally {
      timeoutTimer?.cancel();
    }

    return completer.future;
  }

  /// Cancels a running command (best-effort SIGTERM, then SIGKILL fallback).
  Future<void> cancel(String commandId) async {
    final run = _runs[commandId];
    if (run == null || run.isTerminal || run._process == null) return;
    _killProcessSafely(run._process!);
    run.status = CommandStatus.cancelled;
    run.finishedAt = DateTime.now();
    _emitLog(commandId, '⛔ Cancelled by user/engine.', LogStreamType.system);
    _statusController.add(run);
  }

  /// Cancels every currently running command — call on app dispose.
  Future<void> cancelAll() async {
    for (final run in _runs.values.where((r) => !r.isTerminal)) {
      await cancel(run.id);
    }
  }

  void _killProcessSafely(Process process) {
    try {
      final terminated = process.kill(ProcessSignal.sigterm);
      if (!terminated) {
        process.kill(ProcessSignal.sigkill);
      }
      // Fallback hard-kill shortly after in case sigterm is ignored.
      Timer(const Duration(seconds: 3), () {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {
          /* already dead */
        }
      });
    } catch (_) {
      // Process may have already exited — safe to ignore.
    }
  }

  void _emitLog(String commandId, String line, LogStreamType type) {
    _logController.add(TerminalLogEvent(commandId: commandId, line: line, type: type));
  }

  String _generateId() =>
      'cmd_${DateTime.now().microsecondsSinceEpoch}_${_runs.length}';

  /// Clears finished command history (does not affect active runs).
  void clearHistory() {
    _runs.removeWhere((_, run) => run.isTerminal);
  }

  void dispose() {
    cancelAll();
    _logController.close();
    _statusController.close();
  }
}
