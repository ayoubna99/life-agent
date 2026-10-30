import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/app_services.dart';
import 'package:life_agent/platform/check_words.dart';

void main() {
  final now = DateTime(2026, 10, 29, 21, 0, 0);
  LifyCheck check(Map<String, Object?> w) =>
      LifyCheck(user: 'abcdef123456', server: 'ok', watcher: w);
  CheckLine line(List<CheckLine> lines, String what) =>
      lines.firstWhere((l) => l.what == what);

  test('a watcher the phone paused is called out, with a battery fix', () {
    final lines = checkLines(
      check({
        'running': true,
        'limits': ['Instagram 30 min'],
        'lastTickAt': now
            .subtract(const Duration(minutes: 40))
            .millisecondsSinceEpoch,
        'lastFront': 'com.instagram.android',
        'battery': false,
        'maker': 'xiaomi',
      }),
      now: now,
    );
    final look = line(lines, 'Last look');
    expect(look.ok, isFalse);
    expect(look.detail, contains('40 min ago'));
    expect(look.detail, contains('allow Battery'));
    expect(line(lines, 'Battery').fix, 'battery');
    // pop-ups allowed: nothing to fix
    expect(line(lines, 'Pop-ups in the background').fix, isNull);
  });

  test('a healthy watcher: recent look, battery fine, no Xiaomi line', () {
    final lines = checkLines(
      check({
        'running': true,
        'lastTickAt': now
            .subtract(const Duration(seconds: 12))
            .millisecondsSinceEpoch,
        'lastFront': 'com.zhiliaoapp.musically',
        'battery': true,
        'maker': 'google',
      }),
      now: now,
    );
    expect(line(lines, 'Last look').ok, isTrue);
    expect(line(lines, 'Last look').detail, startsWith('12 s ago'));
    expect(line(lines, 'Battery').fix, isNull);
    expect(lines.any((l) => l.what == 'Pop-ups in the background'), isFalse);
  });

  test('the watcher log reads newest first, and slow nudges are explained', () {
    final c = check({
      'log': [
        '21:00:01 Instagram: asking Lify',
        '21:00:09 Instagram: nudge shown as card',
      ],
    });
    expect(watcherLog(c).first, contains('shown as card'));
    expect(problemWords('nudge_slow'), contains('too long'));
  });

  test('Xiaomi with pop-ups blocked, and what the last nights look like', () {
    final lines = checkLines(
      check({
        'maker': 'redmi',
        'popupBlocked': true,
        'nights': [
          '2026-10-28: 02:15 to 09:40',
          '2026-10-27: none, the longest quiet stretch was 1 h 40, a night needs 3 h',
        ],
      }),
      now: now,
    );
    expect(line(lines, 'Pop-ups in the background').ok, isFalse);
    expect(line(lines, 'Pop-ups in the background').fix, 'popup');
    expect(
      line(lines, 'Night of 2026-10-28').detail,
      '02:15 phone down, picked up 09:40',
    );
    expect(line(lines, 'Night of 2026-10-27').ok, isFalse);
  });
}
