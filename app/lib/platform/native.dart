import 'package:flutter/services.dart';

import '../agent/models.dart';
import '../device/device_runner.dart';

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
  });

  Future<void> cancelAlarm(String id);

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
}

class MethodChannelNative implements Native {
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
  }) => _call<bool>('scheduleAlarm', {
    'id': id,
    'at': atMillis,
    'message': message,
  });

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
}

class NativeAlarmScheduler implements AlarmScheduler {
  NativeAlarmScheduler(this.native);

  final Native native;

  @override
  Future<bool> schedule({
    required String id,
    required DateTime at,
    required String message,
  }) async {
    try {
      return await native.scheduleAlarm(
        id: id,
        atMillis: at.millisecondsSinceEpoch,
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
  UsageSync({required this.native, required this.upload});

  final Native native;
  final Future<void> Function(List<UsageRow>) upload;

  /// `needsPermission` is true when the user has not turned on Usage access yet (the agent then plans without real numbers).
  Future<UsageSyncResult> run({int days = 7}) async {
    try {
      if (!await native.hasUsageAccess())
        return const UsageSyncResult(needsPermission: true);
      final rows = await native.usageSummary(days: days);
      if (rows.isNotEmpty) await upload(rows);
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
