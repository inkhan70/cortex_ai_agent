// lib/services/search_service.dart
//
// SearchService
// ----------------------------------------------------------------------------
// Dynamic web-search fallback used by the Cortex Loop when a lint/build/test
// step fails with an error that looks like a missing-dependency or
// compilation problem. Supports Tavily and Google Custom Search (CSE).
//
// SECURITY NOTE: API keys must never be hardcoded. They are read from
// SharedPreferences (user-entered in Settings) or from --dart-define at
// build time. Never commit real keys to source control.
// ----------------------------------------------------------------------------

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum SearchProvider { tavily, googleCse }

class SearchResult {
  final String title;
  final String url;
  final String snippet;
  SearchResult({required this.title, required this.url, required this.snippet});

  factory SearchResult.fromTavily(Map<String, dynamic> json) => SearchResult(
        title: (json['title'] ?? '') as String,
        url: (json['url'] ?? '') as String,
        snippet: (json['content'] ?? '') as String,
      );

  factory SearchResult.fromGoogle(Map<String, dynamic> json) => SearchResult(
        title: (json['title'] ?? '') as String,
        url: (json['link'] ?? '') as String,
        snippet: (json['snippet'] ?? '') as String,
      );
}

/// Heuristics that decide whether stderr output warrants a web-search repair.
class ErrorSignatureDetector {
  static final List<RegExp> _missingDependencyPatterns = [
    RegExp(r"Target of URI doesn't exist: '([^']+)'", caseSensitive: false),
    RegExp(r"Couldn't resolve the package '([\w_]+)'", caseSensitive: false),
    RegExp(r"Error: Type '([\w<>]+)' not found", caseSensitive: false),
    RegExp(r"module not found", caseSensitive: false),
    RegExp(r"Cannot find module '([^']+)'", caseSensitive: false),
    RegExp(r"No matching package found for '([\w_]+)'", caseSensitive: false),
    RegExp(r"Undefined name '([\w_]+)'", caseSensitive: false),
    RegExp(r"Compilation failed", caseSensitive: false),
  ];

  /// Returns a focused search query built from the first matching error, or
  /// null if nothing actionable was detected in [stderr].
  static String? extractQueryFromStderr(String stderr) {
    for (final pattern in _missingDependencyPatterns) {
      final match = pattern.firstMatch(stderr);
      if (match != null) {
        final captured = match.groupCount >= 1 ? match.group(1) : match.group(0);
        return 'Dart Flutter fix: ${captured ?? match.group(0)}';
      }
    }
    return null;
  }
}

class SearchService {
  SearchService._internal();
  static final SearchService instance = SearchService._internal();

  static const _kTavilyKeyPref = 'tavily_api_key';
  static const _kGoogleKeyPref = 'google_cse_api_key';
  static const _kGoogleCxPref = 'google_cse_cx';
  static const _kProviderPref = 'search_provider';

  Future<void> setProvider(SearchProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProviderPref, provider.name);
  }

  Future<SearchProvider> getProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kProviderPref) ?? SearchProvider.tavily.name;
    return SearchProvider.values.firstWhere((p) => p.name == name,
        orElse: () => SearchProvider.tavily);
  }

  Future<void> saveTavilyKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTavilyKeyPref, key);
  }

  Future<void> saveGoogleCredentials({required String apiKey, required String cx}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kGoogleKeyPref, apiKey);
    await prefs.setString(_kGoogleCxPref, cx);
  }

  /// Runs a web search against the configured provider. Returns an empty
  /// list (never throws to the caller) if keys are missing or the network
  /// request fails — callers should treat empty results as "no repair
  /// context available" rather than a hard failure.
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    try {
      final provider = await getProvider();
      switch (provider) {
        case SearchProvider.tavily:
          return _searchTavily(query, maxResults);
        case SearchProvider.googleCse:
          return _searchGoogle(query, maxResults);
      }
    } catch (e) {
      // Network/API failures degrade gracefully — the loop just proceeds
      // without external repair context.
      return [];
    }
  }

  Future<List<SearchResult>> _searchTavily(String query, int maxResults) async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_kTavilyKeyPref);
    if (key == null || key.isEmpty) return [];

    final resp = await http
        .post(
          Uri.parse('https://api.tavily.com/search'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'api_key': key,
            'query': query,
            'search_depth': 'advanced',
            'max_results': maxResults,
            'include_answer': false,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final results = (data['results'] as List<dynamic>? ?? []);
    return results
        .map((r) => SearchResult.fromTavily(r as Map<String, dynamic>))
        .toList();
  }

  Future<List<SearchResult>> _searchGoogle(String query, int maxResults) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString(_kGoogleKeyPref);
    final cx = prefs.getString(_kGoogleCxPref);
    if (apiKey == null || apiKey.isEmpty || cx == null || cx.isEmpty) return [];

    final uri = Uri.parse('https://www.googleapis.com/customsearch/v1').replace(
      queryParameters: {
        'key': apiKey,
        'cx': cx,
        'q': query,
        'num': maxResults.clamp(1, 10).toString(),
      },
    );

    final resp = await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (data['items'] as List<dynamic>? ?? []);
    return items
        .map((r) => SearchResult.fromGoogle(r as Map<String, dynamic>))
        .toList();
  }

  /// Formats search results into a compact context block suitable for
  /// injection into a model repair prompt.
  String buildRepairContext(List<SearchResult> results) {
    if (results.isEmpty) return '';
    final buffer = StringBuffer('--- WEB REPAIR CONTEXT ---\n');
    for (final r in results.take(5)) {
      buffer.writeln('• ${r.title}');
      buffer.writeln('  ${r.url}');
      buffer.writeln('  ${r.snippet}');
      buffer.writeln();
    }
    buffer.writeln('--- END WEB REPAIR CONTEXT ---');
    return buffer.toString();
  }
}
