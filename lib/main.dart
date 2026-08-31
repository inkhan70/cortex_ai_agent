// lib/main.dart
//
// Cortex AI Agent — app entrypoint. Wires up Provider state for the
// CortexLoopEngine and hosts a Material 3 bottom-nav shell across the
// Terminal, Offline Hub, and Analytics screens.
// ----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'services/cortex_loop_engine.dart';
import 'services/terminal_runner_service.dart';
import 'screens/terminal_screen.dart';
import 'screens/offline_hub_screen.dart';
import 'screens/analytics_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CortexAiAgentApp());
}

class CortexAiAgentApp extends StatelessWidget {
  const CortexAiAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => CortexLoopEngine(
            // NOTE: point this at a real project checkout on a supported
            // desktop/companion-agent target — see terminal_runner_service.dart
            // platform note for why raw mobile can't run a flutter toolchain.
            projectPath: '.',
          ),
        ),
      ],
      child: MaterialApp(
        title: 'Cortex AI Agent',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6750A4),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6750A4),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const RootShell(),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  final _screens = const [
    _CortexHomeScreen(),
    TerminalScreen(),
    OfflineHubScreen(),
    AnalyticsScreen(),
  ];

  @override
  void dispose() {
    // Ensure no orphaned background processes survive app teardown.
    TerminalRunnerService.instance.cancelAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(LucideIcons.layoutDashboard), label: 'Cortex'),
          NavigationDestination(icon: Icon(LucideIcons.terminal), label: 'Terminal'),
          NavigationDestination(icon: Icon(LucideIcons.hardDrive), label: 'Offline Hub'),
          NavigationDestination(icon: Icon(LucideIcons.lineChart), label: 'Analytics'),
        ],
      ),
    );
  }
}

/// Home / dashboard screen — kicks off the autonomous pipeline.
class _CortexHomeScreen extends StatelessWidget {
  const _CortexHomeScreen();

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<CortexLoopEngine>();

    return Scaffold(
      appBar: AppBar(title: const Text('Cortex AI Agent')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.bot, size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Autonomous Cortex Loop',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Resolve Dependencies → Lint → Test → Build,\n'
                'with automated web-search-assisted repair on failure.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: engine.isRunning
                    ? null
                    : () => engine.runFullPipeline(),
                icon: engine.isRunning
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(LucideIcons.play),
                label: Text(engine.isRunning ? 'Running Pipeline...' : 'Run Autonomous Pipeline'),
              ),
              if (engine.isRunning) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => engine.cancel(),
                  icon: const Icon(LucideIcons.octagonX),
                  label: const Text('Cancel'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
