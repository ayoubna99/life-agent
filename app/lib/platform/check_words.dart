import '../app_services.dart';

/// One line of Settings > Check Lify, in plain words.
class CheckLine {
  const CheckLine(this.what, this.ok, this.detail, {this.fix});

  final String what;
  final bool ok;
  final String detail;

  /// A setting that fixes it, opened by a button: "battery" or "popup".
  final String? fix;
}

/// "12 s ago", "5 min ago", "3 h ago".
String ago(Duration d) => d.inSeconds < 90
    ? '${d.inSeconds} s ago'
    : d.inMinutes < 90
    ? '${d.inMinutes} min ago'
    : '${d.inHours} h ago';

/// The watcher's recent decisions, newest first ("21:04:12 Instagram: nudge shown as card").
List<String> watcherLog(LifyCheck c) => [
  for (final l in (c.watcher['log'] as List? ?? const []).reversed) '$l',
];

/// The watcher's and the server's problem codes, said plainly with what to do.
String problemWords(String code) {
  if (code == 'no_usage_access')
    return 'Usage access is off, so it cannot see which app is open. Turn it on below.';
  if (code == 'no_session')
    return 'It could not use your session with Lify. Open the app once, then check again.';
  if (code == 'not_configured')
    return 'It does not know the server yet. Open the app once.';
  if (code == 'network') return 'No connection when it tried.';
  if (code == 'nudge_slow')
    return 'Lify took too long to write a nudge (over 30 s), so it was skipped. Deploy the agent function again if this repeats.';
  if (code == 'session_lost')
    return 'Your session is no longer valid. Start over below (your old plans stay on the server under the old account).';
  if (code == 'daily_limit_reached' || code.endsWith('daily_limit_reached'))
    return 'Today\'s Lify requests are used up. They come back tomorrow.';
  if (code == 'unknown_action' || code.endsWith('unknown_action'))
    return 'The server is an older version. Deploy the agent function again.';
  if (code.startsWith('agent_') || code.startsWith('nudge_agent_'))
    return 'The AI service had a problem ($code). Try again in a minute.';
  return 'Problem: $code';
}

List<CheckLine> checkLines(LifyCheck c, {DateTime? now}) {
  final w = c.watcher;
  final limits = [for (final l in (w['limits'] as List? ?? const [])) '$l'];
  final rules = (w['rules'] as num?)?.toInt() ?? 0;
  final problem = w['lastProblem'] as String?;
  final at = (w['lastProblemAt'] as num?)?.toInt() ?? 0;
  final when = at == 0
      ? ''
      : ' (${DateTime.fromMillisecondsSinceEpoch(at).toString().substring(5, 16)})';
  final sleep = w['eveningSleep'] as String?;
  final tickAt = (w['lastTickAt'] as num?)?.toInt() ?? 0;
  final since = (now ?? DateTime.now()).difference(
    DateTime.fromMillisecondsSinceEpoch(tickAt),
  );
  final front = w['lastFront'] as String?;
  final maker = (w['maker'] as String?) ?? '';
  final xiaomi = ['xiaomi', 'redmi', 'poco'].contains(maker);
  return [
    CheckLine(
      'Account',
      c.user != null,
      c.user == null
          ? 'No session yet'
          : 'Signed in as ${c.user!.substring(0, 8)}…',
    ),
    CheckLine(
      'Server',
      c.server == 'ok',
      c.server == 'ok' ? 'Lify answers' : problemWords(c.server),
    ),
    CheckLine(
      'Watcher',
      w['running'] == true,
      w['running'] == true
          ? 'Running'
          : limits.isEmpty && rules == 0
          ? 'Stopped: no app to watch. Choose the apps that pull you away in Settings (each gets 30 min a day until Start my day sets limits), then Save.'
          : 'Not running. Open the app once to start it.',
    ),
    if (w['running'] == true)
      CheckLine(
        'Last look',
        tickAt != 0 && since.inMinutes < 2,
        tickAt == 0
            ? 'Not yet'
            : '${ago(since)}${front == null ? '' : ', app in front: $front'}${since.inMinutes < 2 ? '' : '. The phone paused the watcher: allow Battery below.'}',
      ),
    if (w.containsKey('battery'))
      CheckLine(
        'Battery',
        w['battery'] == true,
        w['battery'] == true
            ? 'Not restricted: the watcher keeps running'
            : 'Restricted: the phone may stop the watcher, and nudges only come when you open Life',
        fix: w['battery'] == true ? null : 'battery',
      ),
    if (xiaomi)
      CheckLine(
        'Pop-ups in the background',
        w['popupBlocked'] != true,
        w['popupBlocked'] == true
            ? 'Off: this phone hides cards until you open Life, so nudges come as notifications. Allow "Display pop-up windows while running in the background" for cards.'
            : 'Allowed: cards can appear over other apps',
        fix: w['popupBlocked'] == true ? 'popup' : null,
      ),
    if (w['asNotifications'] == true)
      const CheckLine(
        'Nudges',
        true,
        'Sent as notifications (your choice below)',
      ),
    // what the phone shows of the last nights ("2026-10-28: 02:10 to 09:05", or why none was found)
    for (final n in (w['nights'] as List? ?? const []))
      CheckLine(
        'Night of ${'$n'.split(': ').first}',
        !'$n'.contains(': none'),
        '$n'
            .split(': ')
            .skip(1)
            .join(': ')
            .replaceFirst(' to ', ' phone down, picked up '),
      ),
    CheckLine(
      'Limits',
      limits.isNotEmpty,
      limits.isEmpty ? 'None yet' : limits.join(', '),
    ),
    CheckLine(
      'Usage access',
      w['usageAccess'] == true,
      w['usageAccess'] == true ? 'On' : 'Off: turn it on below',
    ),
    CheckLine(
      'Show over other apps',
      w['overlay'] == true,
      w['overlay'] == true
          ? 'On: nudges and alarms appear as cards'
          : 'Off: turn it on below',
    ),
    CheckLine(
      'Experiments',
      true,
      '${w['experiments'] == true ? 'On' : 'Off'}${w['demo'] == true ? ', demo mode' : ''}',
    ),
    CheckLine(
      'Evening reminder',
      sleep != null,
      sleep == null ? 'Not set: save a sleep time' : 'One hour before $sleep',
    ),
    CheckLine(
      'Last problem',
      problem == null,
      problem == null ? 'None' : '${problemWords(problem)}$when',
    ),
  ];
}
