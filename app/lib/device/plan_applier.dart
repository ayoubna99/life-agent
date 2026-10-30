import '../agent/models.dart';
import '../platform/native.dart';
import 'device_runner.dart';
import 'stores.dart';

/// Puts a saved plan on the phone the moment it exists: the night before, not when "Start my day" is pressed in the
/// morning. Plain code, no model: the tasks (with their notes, links and steps for the task screen), an alarm for each
/// timed task ("in_app": Life rings and opens the task's screen; "phone": a real Clock alarm 10 minutes before), and a
/// reminder 10 minutes before each timed calendar event. Applying the same plan twice changes nothing.
class PlanApplier {
  PlanApplier({
    required this.tasks,
    required this.alarms,
    required this.log,
    required this.native,
  });

  final TaskStore tasks;
  final AlarmScheduler alarms;
  final AlarmLog log;
  final Native native;

  static String fingerprint(SavedPlan p) => _hash(
    p.tasks
        .map((t) => '${t.title}|${t.startTime}|${t.minutes}|${t.alarm}')
        .join(';'),
  );

  /// Whether [plan] (this exact version) is already on the phone.
  Future<bool> applied(SavedPlan plan) async =>
      (await log.ids(plan.date)).contains('applied:${fingerprint(plan)}');

  /// Returns how many alarms and reminders were set (0 when it was already applied).
  Future<int> apply(SavedPlan plan, {required DateTime now}) async {
    if (await applied(plan)) return 0;
    final done = await log.ids(plan.date);
    final day = DateTime.parse(plan.date);
    var set = 0;
    for (final t in plan.tasks) {
      final saved = await tasks.upsert(
        LocalTask(
          id: 'plan-${plan.date}-${_hash(t.title)}',
          date: plan.date,
          title: t.title,
          minutes: t.minutes,
          firstStep: t.firstStep,
          instructions: t.instructions,
          links: t.links,
          startTime: t.startTime,
          notes: t.notes,
        ),
      );
      final start = t.startTime;
      if (start == null) continue;
      final at = DateTime(
        day.year,
        day.month,
        day.day,
        int.parse(start.substring(0, 2)),
        int.parse(start.substring(3)),
      );
      if (t.alarm == 'phone') {
        final ring = at.subtract(const Duration(minutes: 10));
        final key = 'phone:${plan.date}:${_hash('${t.title}$start')}';
        if (!ring.isAfter(now) || done.contains(key)) continue;
        // The Clock app rings at the NEXT time it shows that hour: right when that is within a day (tomorrow 07:00
        // set at 22:00), wrong for tomorrow 23:30 set at 22:00 (it would ring tonight). Then Life rings instead.
        final rightDay = ring.difference(now) < const Duration(hours: 24);
        final ok = rightDay
            ? await alarms.phoneAlarm(
                hour: ring.hour,
                minute: ring.minute,
                message: t.title,
              )
            : await alarms.schedule(
                id: key,
                at: ring,
                message: 'Get ready: ${t.title}',
                card: true,
                title: t.title,
                open: 'task:${saved.id}',
              );
        if (ok) {
          await log.add(plan.date, key);
          set++;
        }
      } else {
        if (!at.isAfter(now)) continue;
        final id = 'task-${plan.date}-${_hash(t.title)}';
        if (await alarms.schedule(
          id: id,
          at: at,
          message: t.title,
          card: true,
          title: t.title,
          open: 'task:${saved.id}',
        )) {
          await log.add(plan.date, id);
          set++;
        }
      }
    }
    try {
      for (final e in await native.calendarEvents(plan.date) ?? const []) {
        if (e.allDay) continue;
        final at = DateTime(
          day.year,
          day.month,
          day.day,
          int.parse(e.start.substring(0, 2)),
          int.parse(e.start.substring(3)),
        ).subtract(const Duration(minutes: 10));
        if (!at.isAfter(now)) continue;
        final id = 'cal-${plan.date}-${e.start}-${_hash(e.title)}';
        if (await alarms.schedule(
          id: id,
          at: at,
          message: 'In 10 minutes: ${e.title}',
          title: 'Lify',
        )) {
          await log.add(plan.date, id);
          set++;
        }
      }
    } catch (_) {
      // no calendar access: the tasks are enough
    }
    await log.add(plan.date, 'applied:${fingerprint(plan)}');
    return set;
  }

  static String _hash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h.toRadixString(36);
  }
}
