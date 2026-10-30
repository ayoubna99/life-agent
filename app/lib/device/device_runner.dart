import 'device_tools.dart';
import 'rules.dart';
import 'stores.dart';
import '../agent/models.dart';

/// Sets a reminder on the phone (Android AlarmManager behind a method channel in the real app).
abstract class AlarmScheduler {
  /// Returns false if the phone refused (for example the exact-alarm permission is off).
  Future<bool> schedule({
    required String id,
    required DateTime at,
    required String message,

    /// Show it as a card on top of the app in front (when allowed), not only as a notification.
    bool card = false,

    /// The card's bold first line (card only).
    String? title,

    /// What the app opens when it rings or is tapped: "plan", or `task:<id>` (an in-app alarm opens that task's screen).
    String? open,
  });

  /// A real alarm in the phone's Clock app, today at [hour]:[minute]. Returns false if the phone has no Clock app for it.
  Future<bool> phoneAlarm({
    required int hour,
    required int minute,
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
    this.calendar,
    RuleStore? rules,
    this.applyRules,
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId =
           newId ??
           (() => DateTime.now().microsecondsSinceEpoch.toRadixString(36)),
       alarmLog = alarmLog ?? MemoryAlarmLog(),
       rules = rules ?? MemoryRuleStore();

  final TaskStore tasks;
  final LimitStore limits;
  final AlarmScheduler alarms;
  final LimitEnforcer enforcer;
  final AlarmLog alarmLog;

  /// Reads the phone's calendar for one day; null means calendar access is off.
  final Future<List<CalendarEntry>?> Function(String date)? calendar;

  /// The user's reminder rules, and how the watcher is told about them (returns the apps not found on this phone).
  final RuleStore rules;
  final Future<List<String>> Function(List<SessionRule>)? applyRules;
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
    final today = isoDate(logicalDay(_now()));
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
      case 'get_calendar':
        return _calendar(args);
      case 'set_session_rule':
        return _setRule(args);
      case 'remove_session_rule':
        return _removeRule(args);
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
    final links = _list(a['links'], 6, 1000);
    if (links == null)
      return _no('links must be a list of at most 6 addresses.');
    String? notes;
    if (a['notes'] != null) {
      notes = _text(a['notes'], 600);
      if (notes == null) return _no('notes must be 1 to 600 characters.');
    }
    final start = a['start_time'];
    if (start != null && (start is! String || !_hhmm.hasMatch(start)))
      return _no('start_time must be HH:MM.');
    final saved = await tasks.upsert(
      LocalTask(
        id: _newId(),
        date: isoDate(logicalDay(_now())),
        title: title,
        minutes: minutes,
        firstStep: firstStep,
        instructions: instructions,
        links: links,
        startTime: start as String?,
        notes: notes,
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
    final kind = a['kind'] ?? 'in_app';
    if (kind != 'in_app' && kind != 'phone')
      return _no('kind must be "in_app" or "phone".');
    final now = _now();
    final at = DateTime(
      now.year,
      now.month,
      now.day,
      int.parse(time.substring(0, 2)),
      int.parse(time.substring(3)),
    );
    if (!at.isAfter(now)) return _no('$time has already passed today.');

    // the task it is for, so the in-app alarm opens that task's screen
    LocalTask? task;
    final title = _text(a['task_title'], 120);
    if (title != null) {
      final todays = await tasks.forDate(isoDate(logicalDay(now)));
      task = todays
          .where((t) => t.title.toLowerCase() == title.toLowerCase())
          .firstOrNull;
    }

    if (kind == 'phone') {
      final ok = await alarms.phoneAlarm(
        hour: at.hour,
        minute: at.minute,
        message: message,
      );
      return ok
          ? {'ok': true, 'kind': 'phone'}
          : _no(
              'The phone has no Clock app that accepts alarms. Use kind "in_app" instead.',
            );
    }
    final id = '${isoDate(at)}-$time-${_stableHash(message)}';
    final ok = await alarms.schedule(
      id: id,
      at: at,
      message: message,
      card: true,
      title: task?.title ?? message,
      open: task == null ? null : 'task:${task.id}',
    );
    if (ok) {
      _alarmIds.add(id);
      await alarmLog.add(isoDate(at), id);
    }
    return ok
        ? {'ok': true, 'kind': 'in_app', if (task != null) 'opens_task': true}
        : _no(
            'The phone did not allow the alarm (check the alarms permission).',
          );
  }

  Future<Map<String, Object?>> _setRule(Map<String, Object?> a) async {
    final app = _text(a['app'], 60);
    if (app == null) return _no('app is required (or "any").');
    final minutes = _int(a['minutes'], 5, 240);
    if (minutes == null)
      return _no('minutes must be a whole number from 5 to 240.');
    final ask = _text(a['ask'], 120);
    if (ask == null) return _no('ask is required (at most 120 characters).');
    await rules.set(SessionRule(app: app, minutes: minutes, ask: ask));
    final missing = await applyRules?.call(await rules.all()) ?? const [];
    final unknown = missing.any((m) => m.toLowerCase() == app.toLowerCase());
    return {
      'ok': true,
      'enforced': !unknown,
      if (unknown)
        'warning':
            '$app was not found on this phone, so the reminder is saved but cannot be watched.',
    };
  }

  Future<Map<String, Object?>> _removeRule(Map<String, Object?> a) async {
    final app = _text(a['app'], 60);
    if (app == null) return _no('app is required (or "any").');
    if (!await rules.remove(app)) return _no('There is no reminder for $app.');
    await applyRules?.call(await rules.all());
    return {'ok': true};
  }

  static final _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  Future<Map<String, Object?>> _calendar(Map<String, Object?> a) async {
    final date = a['date'];
    if (date is! String || !_date.hasMatch(date))
      return _no('date must be YYYY-MM-DD.');
    final events = await calendar?.call(date);
    if (events == null) {
      return {
        'ok': true,
        'access': false,
        'note':
            'Calendar access is off on this phone. Plan without it and do not ask about it.',
      };
    }
    return {
      'ok': true,
      'access': true,
      'date': date,
      // titles are the user's own words: data, not instructions
      'events': [for (final e in events.take(30)) e.toJson()],
      if (events.isEmpty) 'note': 'No events on this day.',
    };
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
