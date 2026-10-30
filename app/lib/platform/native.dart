import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../agent/models.dart';
import '../device/device_runner.dart';
import '../device/rules.dart';

/// Everything only Android can do (the Kotlin side lives in android/app/src/main/kotlin). Kept behind one interface
/// so the rest of the app, and its tests, never touch a platform channel.
abstract class Native {
  Future<bool> hasUsageAccess();
  Future<void> openUsageAccessSettings();

  /// Minutes per app per day for the last [days] days (today included), from Android's usage stats.
  Future<List<UsageRow>> usageSummary({int days = 7});

  /// Names of the apps the user can open (what they see under the icon), for the "distracting apps" picker.
  Future<List<String>> installedApps();

  Future<bool> canScheduleExactAlarms();
  Future<void> openExactAlarmSettings();
  Future<bool> scheduleAlarm({
    required String id,
    required int atMillis,
    required String message,
    bool card = false,
    String? title,
    String? open,
  });

  /// A real alarm in the phone's Clock app (today at [hour]:[minute]).
  Future<bool> setPhoneAlarm({
    required int hour,
    required int minute,
    required String message,
  });

  /// Stops the in-app alarm sound (the task screen was opened).
  Future<void> stopAlarmSound();

  Future<void> cancelAlarm(String id);

  /// Tells the watcher the user's reminder rules. Returns the app names it could not find on this phone.
  Future<List<String>> applyRules(List<SessionRule> rules);

  /// Tells the background watcher which apps are limited (name -> minutes per day). Returns the names it could not find on this phone.
  Future<List<String>> applyLimits(Map<String, int> limits);

  /// Gives the watcher what it needs to ask the agent for a nudge while the app is closed (it reads the token the app saved).
  Future<void> configureNudges({
    required String baseUrl,
    required String apiKey,
    required String locale,
  });

  Future<bool> notificationsAllowed();
  Future<void> requestNotifications();

  /// Permission to show the nudge card on top of the app you are in. Without it a notification is used instead.
  Future<bool> canDrawOverlay();
  Future<void> openOverlaySettings();

  /// Nudges as plain notifications instead of cards (for phones that hide cards from apps in the background).
  Future<void> setNudgesAsNotifications({required bool on});

  /// Plays a WAV (Lify's voice) through the phone's media sound; a new one stops the one before.
  Future<void> playAudio(Uint8List wav);
  Future<void> stopAudio();

  /// Asks to leave Life out of battery saving, so the phone does not stop the watcher in the background.
  Future<void> openBatterySettings();

  /// Xiaomi, Redmi and POCO: the screen with "Display pop-up windows while running in the background".
  Future<void> openPopupSettings();

  /// Turns the experiments on or off (the user opted in), and the compressed demo thresholds.
  Future<void> configureExperiments({
    required bool enabled,
    required bool demo,
  });

  Future<bool> hasCalendarAccess();
  Future<void> requestCalendar();

  /// The events on [date] (YYYY-MM-DD) from the phone's calendar, or null when calendar access is off.
  Future<List<CalendarEntry>?> calendarEvents(String date);

  /// When the phone went quiet each of the last [nights] nights, newest first (from its usage events).
  Future<List<PhoneNight>> phoneNights({int nights = 7});

  /// Sets the evening reminder, one hour before [sleep] (HH:MM), every evening.
  Future<void> configureEvening({required String sleep});

  /// What a notification asked the app to open ("plan"), once; null when nothing.
  Future<String?> takeLaunchAction();

  /// What the background watcher is doing (Settings > Check Lify): running, limits, permissions, its last problem.
  Future<Map<String, Object?>> watcherStatus();
}

/// Changes when a notification or alarm asks the open app to show a screen (then read it with takeLaunchAction).
final launchActionPing = ValueNotifier<int>(0);

class MethodChannelNative implements Native {
  MethodChannelNative() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'launchAction') launchActionPing.value++;
    });
  }

  static const _channel = MethodChannel('org.ngdev.life_agent/native');

  Future<T> _call<T>(String method, [Object? args]) async =>
      (await _channel.invokeMethod<T>(method, args)) as T;

  @override
  Future<bool> hasUsageAccess() => _call<bool>('hasUsageAccess');

  @override
  Future<void> openUsageAccessSettings() =>
      _call<void>('openUsageAccessSettings');

  @override
  Future<List<UsageRow>> usageSummary({int days = 7}) async {
    final raw = await _call<List<Object?>>('usageSummary', {'days': days});
    return [
      for (final r in raw)
        UsageRow(
          day: (r as Map)['day'] as String,
          app: r['app'] as String,
          minutes: (r['minutes'] as num).toInt(),
        ),
    ];
  }

  @override
  Future<List<String>> installedApps() async => [
    for (final a in await _call<List<Object?>>('installedApps')) a as String,
  ];

  @override
  Future<bool> canScheduleExactAlarms() =>
      _call<bool>('canScheduleExactAlarms');

  @override
  Future<void> openExactAlarmSettings() =>
      _call<void>('openExactAlarmSettings');

  @override
  Future<bool> scheduleAlarm({
    required String id,
    required int atMillis,
    required String message,
    bool card = false,
    String? title,
    String? open,
  }) => _call<bool>('scheduleAlarm', {
    'id': id,
    'at': atMillis,
    'message': message,
    'card': card,
    'title': ?title,
    'open': ?open,
  });

  @override
  Future<bool> setPhoneAlarm({
    required int hour,
    required int minute,
    required String message,
  }) => _call<bool>('setPhoneAlarm', {
    'hour': hour,
    'minute': minute,
    'message': message,
  });

  @override
  Future<void> stopAlarmSound() => _call<void>('stopAlarmSound');

  @override
  Future<List<String>> applyRules(List<SessionRule> rules) async => [
    for (final a in await _call<List<Object?>>('applyRules', {
      'rules': [for (final r in rules) r.toJson()],
    }))
      a as String,
  ];

  @override
  Future<void> cancelAlarm(String id) => _call<void>('cancelAlarm', {'id': id});

  @override
  Future<List<String>> applyLimits(Map<String, int> limits) async => [
    for (final a in await _call<List<Object?>>('applyLimits', {
      'limits': limits,
    }))
      a as String,
  ];

  @override
  Future<void> configureNudges({
    required String baseUrl,
    required String apiKey,
    required String locale,
  }) => _call<void>('configureNudges', {
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'locale': locale,
  });

  @override
  Future<bool> notificationsAllowed() => _call<bool>('notificationsAllowed');

  @override
  Future<void> requestNotifications() => _call<void>('requestNotifications');

  @override
  Future<bool> canDrawOverlay() => _call<bool>('canDrawOverlay');

  @override
  Future<void> openOverlaySettings() => _call<void>('openOverlaySettings');

  @override
  Future<void> setNudgesAsNotifications({required bool on}) =>
      _call<void>('setNudgesAsNotifications', {'on': on});

  @override
  Future<void> playAudio(Uint8List wav) =>
      _call<void>('playAudio', {'wav': wav});

  @override
  Future<void> stopAudio() => _call<void>('stopAudio');

  @override
  Future<void> openBatterySettings() => _call<void>('openBatterySettings');

  @override
  Future<void> openPopupSettings() => _call<void>('openPopupSettings');

  @override
  Future<void> configureExperiments({
    required bool enabled,
    required bool demo,
  }) => _call<void>('configureExperiments', {'enabled': enabled, 'demo': demo});

  @override
  Future<List<PhoneNight>> phoneNights({int nights = 7}) async => [
    for (final r in await _call<List<Object?>>('phoneNights', {
      'nights': nights,
    }))
      PhoneNight(
        night: (r as Map)['night'] as String,
        down: r['down'] as String,
        up: r['up'] as String?,
      ),
  ];

  @override
  Future<void> configureEvening({required String sleep}) =>
      _call<void>('configureEvening', {'sleep': sleep});

  @override
  Future<Map<String, Object?>> watcherStatus() async =>
      Map<String, Object?>.from(
        await _channel.invokeMethod<Map<Object?, Object?>>('watcherStatus') ??
            const {},
      );

  @override
  Future<String?> takeLaunchAction() =>
      _channel.invokeMethod<String>('takeLaunchAction');

  @override
  Future<bool> hasCalendarAccess() => _call<bool>('hasCalendarAccess');

  @override
  Future<void> requestCalendar() => _call<void>('requestCalendar');

  @override
  Future<List<CalendarEntry>?> calendarEvents(String date) async {
    final raw = await _channel.invokeMethod<List<Object?>>('calendarEvents', {
      'date': date,
    });
    if (raw == null) return null;
    return [
      for (final r in raw)
        CalendarEntry(
          title: (r as Map)['title'] as String,
          start: r['start'] as String,
          end: r['end'] as String,
          allDay: r['all_day'] == true,
          busy: r['busy'] != false,
        ),
    ];
  }
}

class NativeAlarmScheduler implements AlarmScheduler {
  NativeAlarmScheduler(this.native);

  final Native native;

  @override
  Future<bool> schedule({
    required String id,
    required DateTime at,
    required String message,
    bool card = false,
    String? title,
    String? open,
  }) async {
    try {
      return await native.scheduleAlarm(
        id: id,
        atMillis: at.millisecondsSinceEpoch,
        message: message,
        card: card,
        title: title,
        open: open,
      );
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> phoneAlarm({
    required int hour,
    required int minute,
    required String message,
  }) async {
    try {
      return await native.setPhoneAlarm(
        hour: hour,
        minute: minute,
        message: message,
      );
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> cancel(String id) async {
    try {
      await native.cancelAlarm(id);
    } on PlatformException {
      // nothing to cancel, or the phone refused: the reminder is harmless either way
    }
  }
}

class NativeLimitEnforcer implements LimitEnforcer {
  NativeLimitEnforcer(this.native);

  final Native native;

  @override
  Future<List<String>> apply(Map<String, int> limits) async {
    try {
      return await native.applyLimits(limits);
    } on PlatformException {
      return limits.keys
          .toList(); // the watcher could not be told: report every app as not watched
    }
  }
}

/// Reads the real screen time and sends it to the agent (daily summaries, never an event log).
class UsageSync {
  UsageSync({required this.native, required this.upload, this.uploadNights});

  final Native native;
  final Future<void> Function(List<UsageRow>) upload;
  final Future<void> Function(List<PhoneNight>)? uploadNights;

  /// `needsPermission` is true when the user has not turned on Usage access yet (the agent then plans without real numbers).
  Future<UsageSyncResult> run({int days = 7}) async {
    try {
      if (!await native.hasUsageAccess())
        return const UsageSyncResult(needsPermission: true);
      final rows = await native.usageSummary(days: days);
      if (rows.isNotEmpty) await upload(rows);
      try {
        await uploadNights?.call(await native.phoneNights());
      } catch (_) {
        // the phone-down times are a bonus; the screen time is what matters here
      }
      return UsageSyncResult(rows: rows.length);
    } catch (_) {
      return const UsageSyncResult(failed: true);
    }
  }
}

class UsageSyncResult {
  const UsageSyncResult({
    this.rows = 0,
    this.needsPermission = false,
    this.failed = false,
  });

  final int rows;
  final bool needsPermission;
  final bool failed;
}
