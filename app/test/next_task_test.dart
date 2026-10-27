import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/device/next_task.dart';
import 'package:life_agent/device/stores.dart';

LocalTask t(String title, {String? at, bool done = false}) => LocalTask(
  id: title,
  date: '2026-10-27',
  title: title,
  minutes: 30,
  startTime: at,
  done: done,
);

void main() {
  final now = DateTime(2026, 10, 27, 12, 30);

  test(
    'the earliest task still to come is next, whatever the order they were added in',
    () {
      expect(
        nextTask([
          t('Gym', at: '17:00'),
          t('Study', at: '14:00'),
          t('Read', at: '20:00'),
        ], now)!.title,
        'Study',
      );
    },
  );

  test('a task starting right now counts as next', () {
    expect(
      nextTask([t('Now', at: '12:30'), t('Later', at: '15:00')], now)!.title,
      'Now',
    );
  });

  test('ticked-off tasks never come up', () {
    expect(
      nextTask([
        t('Study', at: '14:00', done: true),
        t('Gym', at: '17:00'),
      ], now)!.title,
      'Gym',
    );
    expect(nextTask([t('Study', at: '14:00', done: true)], now), isNull);
    expect(nextTask([], now), isNull);
  });

  test(
    'with nothing still to come, a task without a time is next, then the most overdue one',
    () {
      expect(
        nextTask([t('Early', at: '08:00'), t('Anytime')], now)!.title,
        'Anytime',
      );
      expect(
        nextTask([
          t('Late morning', at: '10:00'),
          t('Early', at: '08:00'),
        ], now)!.title,
        'Early',
      );
    },
  );
}
