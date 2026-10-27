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
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId =
           newId ??
           (() => DateTime.now().microsecondsSinceEpoch.toRadixString(36));

  final TaskStore tasks;
  final LimitStore limits;
  final AlarmScheduler alarms;
  final LimitEnforcer enforcer;
  final DateTime Function() _now;
  final String Function() _newId;

  Map<String, Object?> _no(String why) => {'ok': false, 'error': why};

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
    return {'ok': true, 'task_id': saved.id};
  }

  Future<Map<String, Object?>> _setLimit(Map<String, Object?> a) async {
    final app = _text(a['app'], 60);
    if (app == null) return _no('app is required.');
    final minutes = _int(a['minutes_per_day'], 5, 720);
    if (minutes == null)
      return _no('minutes_per_day must be a whole number from 5 to 720.');
    await limits.set(app, minutes);
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
    final ok = await alarms.schedule(
      id: '${isoDate(at)}-$time-${message.hashCode}',
      at: at,
      message: message,
    );
    return ok
        ? {'ok': true}
        : _no(
            'The phone did not allow the reminder (check the alarms permission).',
          );
  }
}
