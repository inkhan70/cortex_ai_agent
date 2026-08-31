// lib/screens/analytics_screen.dart
//
// AnalyticsScreen — self-improvement analytics & evolution graph.
// Plots Loop Attempt Count vs. Evaluation Score (0-100) using fl_chart, and
// surfaces summary stats: Initial vs. Final Score, Automated Repair Count,
// and Test Pass Rate.
// ----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../services/cortex_loop_engine.dart';

class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<CortexLoopEngine>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Evolution Analytics')),
      body: engine.attempts.isEmpty
          ? const Center(child: Text('Run the Cortex Loop to generate analytics.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatRow(engine: engine),
                const SizedBox(height: 24),
                Text('Loop Attempt vs. Evaluation Score',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: 1.6,
                  child: LineChart(_buildChartData(engine, scheme)),
                ),
                const SizedBox(height: 24),
                Text('Attempt Log', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ...engine.attempts.reversed.map((a) => Card(
                      child: ListTile(
                        leading: Icon(
                          a.success ? LucideIcons.checkCircle2 : LucideIcons.alertTriangle,
                          color: a.success ? Colors.green : Colors.orange,
                        ),
                        title: Text('#${a.attemptNumber} · ${a.stage.label} · Score ${a.score}'),
                        subtitle: Text(a.summary),
                        trailing: a.usedWebRepair
                            ? const Tooltip(
                                message: 'Web-search-assisted repair used',
                                child: Icon(LucideIcons.globe, size: 18),
                              )
                            : null,
                      ),
                    )),
              ],
            ),
    );
  }

  LineChartData _buildChartData(CortexLoopEngine engine, ColorScheme scheme) {
    final spots = <FlSpot>[
      for (int i = 0; i < engine.attempts.length; i++)
        FlSpot(i.toDouble(), engine.attempts[i].score.toDouble()),
    ];

    return LineChartData(
      minY: 0,
      maxY: 100,
      gridData: FlGridData(show: true, horizontalInterval: 20),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, interval: 20, reservedSize: 36),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: (spots.length / 6).clamp(1, double.infinity).toDouble(),
            getTitlesWidget: (value, meta) => Text('#${value.toInt() + 1}'),
          ),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: true),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: scheme.primary,
          barWidth: 3,
          dotData: const FlDotData(show: true),
          belowBarData: BarAreaData(show: true, color: scheme.primary.withOpacity(0.12)),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.engine});
  final CortexLoopEngine engine;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.4,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      children: [
        _StatCard(label: 'Initial Score', value: '${engine.initialScore ?? "-"}'),
        _StatCard(label: 'Final Score', value: '${engine.finalScore ?? "-"}'),
        _StatCard(label: 'Automated Repairs', value: '${engine.automatedRepairCount}'),
        _StatCard(
          label: 'Test Pass Rate',
          value: '${(engine.testPassRate * 100).toStringAsFixed(0)}%',
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}
