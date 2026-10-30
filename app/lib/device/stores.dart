import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One task on the Today list (made by the agent in the morning run).
class LocalTask {
  const LocalTask({
    required this.id,
    required this.date,
    required this.title,
    required this.minutes,
    this.firstStep,
    this.instructions = const [],
    this.links = const [],
    this.startTime,
    this.done = false,
    this.notes,
  });

  final String id;
  final String date; // YYYY-MM-DD
  final String title;
  final int minutes;
  final String? firstStep;
  final List<String> instructions;
  final List<String> links;
  final String? startTime; // HH:MM
  final bool done;

  /// What was decided in the chat about this task (shown on its screen).
  final String? notes;

  LocalTask copyWith({bool? done}) => LocalTask(
    id: id,
    date: date,
    title: title,
    minutes: minutes,
    firstStep: firstStep,
    instructions: instructions,
    links: links,
    startTime: startTime,
    done: done ?? this.done,
    notes: notes,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'date': date,
    'title': title,
    'minutes': minutes,
    if (firstStep != null) 'first_step': firstStep,
    'instructions': instructions,
    'links': links,
    if (startTime != null) 'start_time': startTime,
    'done': done,
    if (notes != null) 'notes': notes,
  };

  factory LocalTask.fromJson(Map<String, Object?> j) => LocalTask(
    id: j['id'] as String,
    date: j['date'] as String,
    title: j['title'] as String,
    minutes: (j['minutes'] as num).toInt(),
    firstStep: j['first_step'] as String?,
    instructions: [
      for (final s in (j['instructions'] as List? ?? const [])) s as String,
    ],
    links: [for (final s in (j['links'] as List? ?? const [])) s as String],
    startTime: j['start_time'] as String?,
    done: j['done'] == true,
    notes: j['notes'] as String?,
  );
}

abstract class TaskStore {
  Future<List<LocalTask>> forDate(String date);

  /// Adds the task, or replaces the one with the same title on the same day (so running the morning plan twice never duplicates).
  /// A task that was already ticked off stays ticked off.
  Future<LocalTask> upsert(LocalTask task);

  Future<void> setDone(String id, bool done);

  Future<void> remove(String id);
}

abstract class LimitStore {
  Future<Map<String, int>> all();
  Future<void> set(String app, int minutesPerDay);
  Future<void> remove(String app);
}

/// The reminders scheduled for each day, so a new plan can cancel the ones it no longer has.
abstract class AlarmLog {
  Future<List<String>> ids(String date);
  Future<void> add(String date, String id);
  Future<void> remove(String date, String id);
}

class MemoryAlarmLog implements AlarmLog {
  final Map<String, Set<String>> _byDate = {};

  @override
  Future<List<String>> ids(String date) async => [...?_byDate[date]];

  @override
  Future<void> add(String date, String id) async =>
      (_byDate[date] ??= {}).add(id);

  @override
  Future<void> remove(String date, String id) async =>
      _byDate[date]?.remove(id);
}

class MemoryTaskStore implements TaskStore {
  final List<LocalTask> _tasks = [];

  @override
  Future<List<LocalTask>> forDate(String date) async => [
    for (final t in _tasks)
      if (t.date == date) t,
  ];

  @override
  Future<LocalTask> upsert(LocalTask task) async {
    final i = _tasks.indexWhere(
      (t) =>
          t.date == task.date &&
          t.title.toLowerCase() == task.title.toLowerCase(),
    );
    if (i >= 0) {
      final kept = task.copyWith(done: _tasks[i].done);
      _tasks[i] = kept;
      return kept;
    }
    _tasks.add(task);
    return task;
  }

  @override
  Future<void> setDone(String id, bool done) async {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i >= 0) _tasks[i] = _tasks[i].copyWith(done: done);
  }

  @override
  Future<void> remove(String id) async => _tasks.removeWhere((t) => t.id == id);
}

class MemoryLimitStore implements LimitStore {
  final Map<String, int> _limits = {};

  @override
  Future<Map<String, int>> all() async => Map.of(_limits);

  @override
  Future<void> set(String app, int minutesPerDay) async =>
      _limits[app] = minutesPerDay;

  @override
  Future<void> remove(String app) async => _limits.remove(app);
}

/// The same stores on the phone (shared_preferences, a small JSON blob). Tasks older than two weeks are dropped when saving.
class PrefsTaskStore implements TaskStore {
  PrefsTaskStore({this.keepDays = 14, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const _key = 'life.tasks';
  final int keepDays;
  final DateTime Function() _now;

  Future<List<LocalTask>> _load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          LocalTask.fromJson(Map<String, Object?>.from(j as Map)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<LocalTask> tasks) async {
    final cutoff = _now().subtract(Duration(days: keepDays));
    final cut =
        '${cutoff.year.toString().padLeft(4, '0')}-${cutoff.month.toString().padLeft(2, '0')}-${cutoff.day.toString().padLeft(2, '0')}';
    final fresh = [
      for (final t in tasks)
        if (t.date.compareTo(cut) >= 0) t.toJson(),
    ];
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(fresh),
    );
  }

  @override
  Future<List<LocalTask>> forDate(String date) async => [
    for (final t in await _load())
      if (t.date == date) t,
  ];

  @override
  Future<LocalTask> upsert(LocalTask task) async {
    final all = await _load();
    final i = all.indexWhere(
      (t) =>
          t.date == task.date &&
          t.title.toLowerCase() == task.title.toLowerCase(),
    );
    LocalTask kept = task;
    if (i >= 0) {
      kept = task.copyWith(done: all[i].done);
      all[i] = kept;
    } else {
      all.add(task);
    }
    await _save(all);
    return kept;
  }

  @override
  Future<void> setDone(String id, bool done) async {
    final all = await _load();
    final i = all.indexWhere((t) => t.id == id);
    if (i < 0) return;
    all[i] = all[i].copyWith(done: done);
    await _save(all);
  }

  @override
  Future<void> remove(String id) async {
    final all = await _load();
    all.removeWhere((t) => t.id == id);
    await _save(all);
  }
}

class PrefsLimitStore implements LimitStore {
  static const _key = 'life.limits';

  @override
  Future<Map<String, int>> all() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map).entries)
          e.key as String: (e.value as num).toInt(),
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> set(String app, int minutesPerDay) async {
    final all = await this.all();
    all[app] = minutesPerDay;
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(all),
    );
  }

  @override
  Future<void> remove(String app) async {
    final all = await this.all();
    if (all.remove(app) == null) return;
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(all),
    );
  }
}

/// Reminder ids per day on the phone (days older than a week are forgotten).
class PrefsAlarmLog implements AlarmLog {
  static const _key = 'life.alarms';

  Future<Map<String, List<String>>> _load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map).entries)
          e.key as String: [for (final v in e.value as List) v as String],
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, List<String>> all) async {
    final days = all.keys.toList()..sort();
    for (final old in days.take((days.length - 7).clamp(0, days.length))) {
      all.remove(old);
    }
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(all),
    );
  }

  @override
  Future<List<String>> ids(String date) async => (await _load())[date] ?? [];

  @override
  Future<void> add(String date, String id) async {
    final all = await _load();
    final list = all[date] ??= [];
    if (!list.contains(id)) list.add(id);
    await _save(all);
  }

  @override
  Future<void> remove(String date, String id) async {
    final all = await _load();
    all[date]?.remove(id);
    await _save(all);
  }
}
