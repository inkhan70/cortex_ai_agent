// lib/screens/offline_hub_screen.dart
//
// OfflineHubScreen — connection manager for local inference servers
// (Ollama / LM Studio / LocalAI) plus offline-cached API doc lookup.
// ----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../services/offline_hub_service.dart';

class OfflineHubScreen extends StatefulWidget {
  const OfflineHubScreen({super.key});

  @override
  State<OfflineHubScreen> createState() => _OfflineHubScreenState();
}

class _OfflineHubScreenState extends State<OfflineHubScreen> {
  final OfflineHubService _hub = OfflineHubService.instance;
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  bool _isProbing = false;
  bool _isAutoDetecting = false;
  List<ServerProbeResult> _detectedServers = [];
  ServerProbeResult? _activeProbe;
  LocalServerConfig? _savedConfig;
  List<Map<String, Object?>> _docResults = [];

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final saved = await _hub.loadActiveServer();
    setState(() {
      _savedConfig = saved;
      if (saved != null) _hostController.text = saved.host;
    });
  }

  Future<void> _autoDetect() async {
    setState(() => _isAutoDetecting = true);
    try {
      final results = await _hub.autoDetect();
      setState(() => _detectedServers = results);
      if (results.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No local servers found on common ports. Try manual entry.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isAutoDetecting = false);
    }
  }

  Future<void> _probeManualHost() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    setState(() => _isProbing = true);
    try {
      final result = await _hub.probeServer(host);
      setState(() => _activeProbe = result);
      if (!result.reachable && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reach $host — ${result.error ?? "no response"}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProbing = false);
    }
  }

  Future<void> _connect(String host, {LocalServerKind kind = LocalServerKind.ollama}) async {
    final config = LocalServerConfig(host: host, kind: kind);
    await _hub.saveActiveServer(config);
    setState(() => _savedConfig = config);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to $host')),
      );
    }
  }

  Future<void> _searchDocs(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _docResults = []);
      return;
    }
    final results = await _hub.lookupDoc(query.trim());
    setState(() => _docResults = results);
  }

  Widget _serverCard(ServerProbeResult r) {
    final isActive = _savedConfig?.host == r.host;
    return Card(
      child: ListTile(
        leading: Icon(
          LucideIcons.server,
          color: isActive ? Colors.green : null,
        ),
        title: Text(r.host, style: const TextStyle(fontFamily: 'monospace')),
        subtitle: Text(
          '${r.latency != null ? "${r.latency!.inMilliseconds}ms · " : ""}'
          '${r.models.length} model(s) available'
          '${r.models.isNotEmpty ? ": ${r.models.map((m) => m.name).take(3).join(", ")}" : ""}',
        ),
        trailing: FilledButton.tonal(
          onPressed: () => _connect(r.host),
          child: Text(isActive ? 'Active' : 'Connect'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Model & Library Hub')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_savedConfig != null)
            Card(
              color: Colors.green.withOpacity(0.08),
              child: ListTile(
                leading: const Icon(LucideIcons.checkCircle2, color: Colors.green),
                title: Text('Connected: ${_savedConfig!.host}'),
                subtitle: Text('Backend: ${_savedConfig!.kind.name}'),
              ),
            ),
          const SizedBox(height: 8),
          Text('Auto-Detect Local Servers', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Scans common local-inference ports (Ollama :11434, LM Studio :1234) '
            'via localhost and the Android emulator host alias (10.0.2.2).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _isAutoDetecting ? null : _autoDetect,
            icon: _isAutoDetecting
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(LucideIcons.radar),
            label: Text(_isAutoDetecting ? 'Scanning...' : 'Auto-Detect'),
          ),
          const SizedBox(height: 12),
          ..._detectedServers.map(_serverCard),

          const Divider(height: 32),
          Text('Manual Server Entry', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Server host',
              hintText: 'http://192.168.1.15:11434',
              border: OutlineInputBorder(),
              prefixIcon: Icon(LucideIcons.link),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isProbing ? null : _probeManualHost,
                  icon: _isProbing
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(LucideIcons.activity),
                  label: const Text('Test Latency'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _connect(_hostController.text.trim()),
                  icon: const Icon(LucideIcons.plugZap),
                  label: const Text('Connect'),
                ),
              ),
            ],
          ),
          if (_activeProbe != null) ...[
            const SizedBox(height: 8),
            _serverCard(_activeProbe!),
          ],

          const Divider(height: 32),
          Text('Offline Cached Docs (Dart/Flutter APIs)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Available without internet — searches the on-device cache populated the last time you were online.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _searchController,
            onChanged: _searchDocs,
            decoration: const InputDecoration(
              labelText: 'Search symbol (e.g. "ListView", "Future")',
              border: OutlineInputBorder(),
              prefixIcon: Icon(LucideIcons.search),
            ),
          ),
          const SizedBox(height: 8),
          ..._docResults.map((doc) => Card(
                child: ListTile(
                  title: Text('${doc['package']}.${doc['symbol']}',
                      style: const TextStyle(fontFamily: 'monospace')),
                  subtitle: Text('${doc['summary']}'),
                ),
              )),
          if (_docResults.isEmpty && _searchController.text.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No cached entries found for this symbol yet.'),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _hostController.dispose();
    _searchController.dispose();
    super.dispose();
  }
}
