import 'device_tools.dart';
import 'stores.dart';
import '../agent/models.dart';

/// Sets a reminder on the phone (Android AlarmManager behind a method channel in the real app).
abstract class AlarmScheduler {
  /// Returns false if the phone refused (for example the exact-alarm permission is off).
  Future<bool> schedule({
    required String id,
    required DateTime at,
    required String message,
  });

  /// Cancels a reminder made earlier (it may already have fired: that is fine).
  Future<void> cancel(String id);
}

/// Tells the background watcher which apps are limited. Returns the apps it could not find on this phone.
abstract class LimitEnforcer {
  Future<List<String>> apply(Map<String, int> limits);
}

final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

/// Does what the agent asks, and says exactly what happened. Bad arguments come back as `{ok: false, error}`:
/// the agent reads that and tells the user, instead of the phone pretending it worked.
class DeviceToolRunner implements DeviceTools {
  DeviceToolRunner({
    required this.tasks,
    required this.limits,
    required this.alarms,
    required this.enforcer,
    AlarmLog? alarmLog,
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId =
           newId ??
           (() => DateTime.now().microsecondsSinceEpoch.toRadixString(36)),
       alarmLog = alarmLog ?? MemoryAlarmLog();

  final TaskStore tasks;
  final LimitStore limits;
  final AlarmScheduler alarms;
  final LimitEnforcer enforcer;
  final AlarmLog alarmLog;
  final DateTime Function() _now;
  final String Function() _newId;

  Map<String, Object?> _no(String why) => {'ok': false, 'error': why};

  // What this run has set up so far; whatever else exists for today is left over from an older plan.
  bool _inRun = false;
  final Set<String> _taskTitles = {};
  final Set<String> _limitApps = {};
  final Set<String> _alarmIds = {};

  @override
  Future<void> beginRun() async {
    _inRun = true;
    _taskTitles.clear();
    _limitApps.clear();
    _alarmIds.clear();
  }

  /// Today now mirrors the plan: tasks that are not done, limits and reminders from an older plan are removed.
  /// Ticked-off tasks stay (they are what happened today).
  @override
  Future<void> endRun() async {
    if (!_inRun) return;
    _inRun = false;
    final today = isoDate(_now());
    for (final t in await tasks.forDate(today)) {
      if (!t.done && !_taskTitles.contains(t.title.toLowerCase())) {
        await tasks.remove(t.id);
      }
    }
    final all = await limits.all();
    final stale = [
      for (final app in all.keys)
        if (!_limitApps.contains(app.toLowerCase())) app,
    ];
    if (stale.isNotEmpty) {
      for (final app in stale) {
        await limits.remove(app);
      }
      await enforcer.apply(await limits.all());
    }
    for (final id in await alarmLog.ids(today)) {
      if (!_alarmIds.contains(id)) {
        await alarms.cancel(id);
        await alarmLog.remove(today, id);
      }
    }
  }

  @override
  Future<Map<String, Object?>> run(String name, Map<String, Object?> args) {
    switch (name) {
      case 'create_task':
        return _createTask(args);
      case 'set_app_limit':
        return _setLimit(args);
      case 'schedule_alarm':
        return _alarm(args);
      default:
        return Future.value(_no('Unknown tool $name.'));
    }
  }

  String? _text(Object? v, int max) =>
      v is String && v.trim().isNotEmpty && v.length <= max ? v.trim() : null;
  int? _int(Object? v, int min, int max) =>
      v is int && v >= min && v <= max ? v : null;
  List<String>? _list(Object? v, int maxItems, int maxChars) {
    if (v == null) return const [];
    if (v is! List || v.length > maxItems) return null;
    final out = <String>[];
    for (final s in v) {
      if (s is! String || s.trim().isEmpty || s.length > maxChars) return null;
      out.add(s.trim());
    }
    return out;
  }

  Future<Map<String, Object?>> _createTask(Map<String, Object?> a) async {
    final title = _text(a['title'], 120);
    if (title == null)
      return _no('title is required (at most 120 characters).');
    final minutes = _int(a['minutes'], 5, 480);
    if (minutes == null)
      return _no('minutes must be a whole number from 5 to 480.');
    String? firstStep;
    if (a['first_step'] != null) {
      firstStep = _text(a['first_step'], 200);
      if (firstStep == null)
        return _no('first_step must be 1 to 200 characters.');
    }
    final instructions = _list(a['instructions'], 8, 300);
    if (instructions == null)
      return _no('instructions must be a list of at most 8 short texts.');
    final links = _list(a['links'], 5, 500);
    if (links == null)
      return _no('links must be a list of at most 5 addresses.');
    final start = a['start_time'];
    if (start != null && (start is! String || !_hhmm.hasMatch(start)))
      return _no('start_time must be HH:MM.');
    final saved = await tasks.upsert(
      LocalTask(
        id: _newId(),
        date: isoDate(_now()),
        title: title,
        minutes: minutes,
        firstStep: firstStep,
        instructions: instructions,
        links: links,
        startTime: start as String?,
      ),
    );
    _taskTitles.add(title.toLowerCase());
    return {'ok': true, 'task_id': saved.id};
  }

  Future<Map<String, Object?>> _setLimit(Map<String, Object?> a) async {
    final app = _text(a['app'], 60);
    if (app == null) return _no('app is required.');
    final minutes = _int(a['minutes_per_day'], 5, 720);
    if (minutes == null)
      return _no('minutes_per_day must be a whole number from 5 to 720.');
    await limits.set(app, minutes);
    _limitApps.add(app.toLowerCase());
    final missing = await enforcer.apply(await limits.all());
    final unknown = missing.any((m) => m.toLowerCase() == app.toLowerCase());
    return {
      'ok': true,
      'enforced': !unknown,
      if (unknown)
        'warning':
            '$app was not found on this phone, so the limit is saved but cannot be watched.',
    };
  }

  Future<Map<String, Object?>> _alarm(Map<String, Object?> a) async {
    final time = a['time'];
    if (time is! String || !_hhmm.hasMatch(time))
      return _no('time must be HH:MM.');
    final message = _text(a['message'], 140);
    if (message == null)
      return _no('message is required (at most 140 characters).');
    final now = _now();
    final at = DateTime(
      now.year,
      now.month,
      now.day,
      int.parse(time.substring(0, 2)),
      int.parse(time.substring(3)),
    );
    if (!at.isAfter(now)) return _no('$time has already passed today.');
    final id = '${isoDate(at)}-$time-${_stableHash(message)}';
    final ok = await alarms.schedule(id: id, at: at, message: message);
    if (ok) {
      _alarmIds.add(id);
      await alarmLog.add(isoDate(at), id);
    }
    return ok
        ? {'ok': true}
        : _no(
            'The phone did not allow the reminder (check the alarms permission).',
          );
  }

  /// The same number for the same text on every run (String.hashCode is not promised to be).
  static String _stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(36);
  }
}
