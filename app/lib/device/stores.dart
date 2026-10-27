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
  );
}

abstract class TaskStore {
  Future<List<LocalTask>> forDate(String date);

  /// Adds the task, or replaces the one with the same title on the same day (so running the morning plan twice never duplicates).
  /// A task that was already ticked off stays ticked off.
  Future<LocalTask> upsert(LocalTask task);

  Future<void> setDone(String id, bool done);
}

abstract class LimitStore {
  Future<Map<String, int>> all();
  Future<void> set(String app, int minutesPerDay);
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
}

class MemoryLimitStore implements LimitStore {
  final Map<String, int> _limits = {};

  @override
  Future<Map<String, int>> all() async => Map.of(_limits);

  @override
  Future<void> set(String app, int minutesPerDay) async =>
      _limits[app] = minutesPerDay;
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
}
