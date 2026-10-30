import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A reminder the user asked for: whenever they spend [minutes] in a row on [app] ("any" for every app), the phone sends
/// them a personal reminder (written by the agent) to do [ask].
class SessionRule {
  const SessionRule({
    required this.app,
    required this.minutes,
    required this.ask,
  });

  final String app;
  final int minutes;
  final String ask;

  bool get anyApp => app.toLowerCase() == 'any';

  Map<String, Object?> toJson() => {'app': app, 'minutes': minutes, 'ask': ask};

  factory SessionRule.fromJson(Map<String, Object?> j) => SessionRule(
    app: j['app'] as String,
    minutes: (j['minutes'] as num).toInt(),
    ask: j['ask'] as String,
  );
}

abstract class RuleStore {
  Future<List<SessionRule>> all();

  /// Adds the rule, or replaces the one for the same app.
  Future<void> set(SessionRule rule);

  /// Returns false when there was no rule for that app.
  Future<bool> remove(String app);
}

class MemoryRuleStore implements RuleStore {
  final List<SessionRule> rules = [];

  @override
  Future<List<SessionRule>> all() async => [...rules];

  @override
  Future<void> set(SessionRule rule) async {
    rules.removeWhere((r) => r.app.toLowerCase() == rule.app.toLowerCase());
    rules.add(rule);
  }

  @override
  Future<bool> remove(String app) async {
    final before = rules.length;
    rules.removeWhere((r) => r.app.toLowerCase() == app.toLowerCase());
    return rules.length < before;
  }
}

class PrefsRuleStore implements RuleStore {
  static const _key = 'life.rules';

  @override
  Future<List<SessionRule>> all() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    try {
      return [
        for (final r in jsonDecode(raw) as List)
          SessionRule.fromJson(Map<String, Object?>.from(r as Map)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<SessionRule> rules) async =>
      (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode([for (final r in rules) r.toJson()]),
      );

  @override
  Future<void> set(SessionRule rule) async {
    final all = await this.all()
      ..removeWhere((r) => r.app.toLowerCase() == rule.app.toLowerCase());
    await _save(all..add(rule));
  }

  @override
  Future<bool> remove(String app) async {
    final all = await this.all();
    final before = all.length;
    all.removeWhere((r) => r.app.toLowerCase() == app.toLowerCase());
    await _save(all);
    return all.length < before;
  }
}
