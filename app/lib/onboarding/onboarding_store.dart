import 'package:shared_preferences/shared_preferences.dart';

import '../agent/models.dart';

/// Whether the welcome slides were done, and the first name they asked for (kept on the phone too, so the greeting
/// works offline; the server keeps a copy for Lify).
abstract class OnboardingStore {
  Future<bool> done();
  Future<void> finish();
  Future<String?> name();
  Future<void> saveName(String name);
}

class MemoryOnboardingStore implements OnboardingStore {
  MemoryOnboardingStore({this.isDone = false, this.firstName});

  bool isDone;
  String? firstName;

  @override
  Future<bool> done() async => isDone;

  @override
  Future<void> finish() async => isDone = true;

  @override
  Future<String?> name() async => firstName;

  @override
  Future<void> saveName(String name) async => firstName = name;
}

class PrefsOnboardingStore implements OnboardingStore {
  static const _done = 'onboarding.done';
  static const _name = 'onboarding.name';

  @override
  Future<bool> done() async =>
      (await SharedPreferences.getInstance()).getBool(_done) ?? false;

  @override
  Future<void> finish() async =>
      (await SharedPreferences.getInstance()).setBool(_done, true);

  @override
  Future<String?> name() async =>
      (await SharedPreferences.getInstance()).getString(_name);

  @override
  Future<void> saveName(String name) async =>
      (await SharedPreferences.getInstance()).setString(_name, name);
}

/// The "reality check": how much the phone takes from a day, from Android's real usage stats.
class RealityCheck {
  const RealityCheck({
    required this.minutesPerDay,
    required this.days,
    required this.topApps,
  });

  /// Average screen time per full day (today is left out when there are earlier days, it is not over yet).
  final int minutesPerDay;
  final int days;

  /// The apps that take the most, with their average minutes per day, biggest first (at most 5).
  final List<(String, int)> topApps;

  bool get empty => minutesPerDay == 0;

  /// Days of a year spent on the phone at this pace (24-hour days).
  double get daysPerYear => minutesPerDay * 365 / 60 / 24;

  /// Share of the waking day (16 hours).
  double get shareOfWakingDay => (minutesPerDay / (16 * 60)).clamp(0, 1);

  factory RealityCheck.from(List<UsageRow> rows, {required String today}) {
    final earlier = rows.where((r) => r.day != today).toList();
    final use = earlier.isNotEmpty ? earlier : rows;
    final days = {for (final r in use) r.day}.length;
    if (days == 0) {
      return const RealityCheck(minutesPerDay: 0, days: 0, topApps: []);
    }
    final perApp = <String, int>{};
    var total = 0;
    for (final r in use) {
      perApp[r.app] = (perApp[r.app] ?? 0) + r.minutes;
      total += r.minutes;
    }
    final top = perApp.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return RealityCheck(
      minutesPerDay: (total / days).round(),
      days: days,
      topApps: [for (final e in top.take(5)) (e.key, (e.value / days).round())],
    );
  }
}

/// 135 -> "2h 15m", 45 -> "45m".
String hoursAndMinutes(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
