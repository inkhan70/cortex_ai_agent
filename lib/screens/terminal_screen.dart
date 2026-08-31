// lib/screens/terminal_screen.dart
//
// TerminalScreen — live autonomous log viewer.
// Renders the real-time stdout/stderr stream from TerminalRunnerService,
// with auto-scroll toggle, clear-logs action, and a status chip per
// tracked command (Running / Success / Failed + exit code).
// ----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../services/terminal_runner_service.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _LogLine {
  final TerminalLogEvent event;
  _LogLine(this.event);
}

class _TerminalScreenState extends State<TerminalScreen> {
  final TerminalRunnerService _runner = TerminalRunnerService.instance;
  final ScrollController _scrollController = ScrollController();
  final List<_LogLine> _lines = [];

  bool _autoScroll = true;
  late final Stream<TerminalLogEvent> _logStream;
  late final Stream<CommandRun> _statusStream;

  @override
  void initState() {
    super.initState();
    _logStream = _runner.logStream;
    _statusStream = _runner.statusStream;
    _logStream.listen(_onLogEvent);
    _statusStream.listen((_) => setState(() {})); // refresh status chips
  }

  void _onLogEvent(TerminalLogEvent event) {
    setState(() => _lines.add(_LogLine(event)));
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _clearLogs() {
    setState(() {
      _lines.clear();
      _runner.clearHistory();
    });
  }

  Color _colorForLine(LogStreamType type, ColorScheme scheme) {
    switch (type) {
      case LogStreamType.stderr:
        return scheme.error;
      case LogStreamType.system:
        return scheme.tertiary;
      case LogStreamType.stdout:
        return scheme.onSurface;
    }
  }

  Widget _statusChip(CommandRun run, ColorScheme scheme) {
    late final Color color;
    late final IconData icon;
    late final String label;

    switch (run.status) {
      case CommandStatus.queued:
        color = scheme.outline;
        icon = LucideIcons.clock;
        label = 'Queued';
        break;
      case CommandStatus.running:
        color = scheme.primary;
        icon = LucideIcons.loader;
        label = 'Running';
        break;
      case CommandStatus.success:
        color = Colors.green;
        icon = LucideIcons.checkCircle2;
        label = 'Success (exit 0)';
        break;
      case CommandStatus.failed:
        color = scheme.error;
        icon = LucideIcons.xCircle;
        label = 'Failed (exit ${run.exitCode ?? "?"})';
        break;
      case CommandStatus.timedOut:
        color = Colors.orange;
        icon = LucideIcons.timer;
        label = 'Timed Out';
        break;
      case CommandStatus.cancelled:
        color = scheme.outline;
        icon = LucideIcons.slash;
        label = 'Cancelled';
        break;
    }

    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(color: color, fontSize: 12)),
      backgroundColor: color.withOpacity(0.1),
      side: BorderSide(color: color.withOpacity(0.4)),
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeRuns = _runner.history.where((r) => true).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Terminal'),
        actions: [
          IconButton(
            tooltip: _autoScroll ? 'Auto-scroll: ON' : 'Auto-scroll: OFF',
            icon: Icon(_autoScroll ? LucideIcons.arrowDownCircle : LucideIcons.pauseCircle),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            tooltip: 'Clear logs',
            icon: const Icon(LucideIcons.trash2),
            onPressed: _clearLogs,
          ),
        ],
      ),
      body: Column(
        children: [
          if (activeRuns.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: activeRuns
                    .map((r) => Tooltip(
                          message: r.fullCommand,
                          child: _statusChip(r, scheme),
                        ))
                    .toList(),
              ),
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              color: Colors.black,
              child: _lines.isEmpty
                  ? Center(
                      child: Text(
                        'No output yet. Trigger a Cortex Loop stage to see live logs.',
                        style: TextStyle(color: Colors.grey.shade500),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _lines.length,
                      itemBuilder: (context, index) {
                        final event = _lines[index].event;
                        return SelectableText(
                          event.line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            color: _colorForLine(event.type, scheme),
                            height: 1.4,
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}
