import 'stores.dart';

/// The task to do next: the earliest one still to come today, otherwise one without a time, otherwise the one that is
/// most overdue. Ticked-off tasks never count. Null when nothing is left.
LocalTask? nextTask(List<LocalTask> tasks, DateTime now) {
  final pending = [
    for (final t in tasks)
      if (!t.done) t,
  ];
  if (pending.isEmpty) return null;
  final nowHm =
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  final timed = [
    for (final t in pending)
      if (t.startTime != null) t,
  ]..sort((a, b) => a.startTime!.compareTo(b.startTime!));
  final upcoming = [
    for (final t in timed)
      if (t.startTime!.compareTo(nowHm) >= 0) t,
  ];
  if (upcoming.isNotEmpty) return upcoming.first;
  final untimed = [
    for (final t in pending)
      if (t.startTime == null) t,
  ];
  if (untimed.isNotEmpty) return untimed.first;
  return timed
      .first; // all the timed ones are in the past: the earliest is the most overdue
}
