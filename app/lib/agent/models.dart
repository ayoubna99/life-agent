// What the agent API sends and receives (see docs/API.md).

class AgentException implements Exception {
  AgentException(this.code, {this.status});

  /// The server's error code (`daily_limit_reached`, `demo_at_capacity`, ...) or one of ours: `network`, `timeout`,
  /// `bad_response`, `auth_failed`, `too_many_tool_rounds`.
  final String code;
  final int? status;

  bool get dailyLimit => code == 'daily_limit_reached';
  bool get capacity => code == 'demo_at_capacity';
  bool get offline => code == 'network';
  bool get timedOut => code == 'timeout' || code == 'agent_timeout';

  @override
  String toString() =>
      'AgentException($code${status != null ? ', $status' : ''})';
}

class ToolCall {
  const ToolCall({required this.id, required this.name, required this.args});

  final String id;
  final String name;
  final Map<String, Object?> args;

  factory ToolCall.fromJson(Map<String, Object?> j) => ToolCall(
    id: j['id'] as String,
    name: j['name'] as String,
    args: Map<String, Object?>.from((j['args'] as Map?) ?? const {}),
  );
}

/// Something the agent made for the user: a PDF sheet, a picture or a markdown file.
class Artifact {
  const Artifact({required this.type, required this.title, required this.url});

  final String type; // pdf | image | markdown
  final String title;
  final String url;

  factory Artifact.fromJson(Map<String, Object?> j) => Artifact(
    type: j['type'] as String,
    title: j['title'] as String,
    url: j['url'] as String,
  );
}

class ChatAnswer {
  const ChatAnswer({
    required this.conversationId,
    this.text,
    this.spoken,
    this.calls = const [],
    this.planSaved = false,
    this.artifacts = const [],
    this.strategyUpdate,
  });

  final String conversationId;

  /// The agent's words, or null when it asked the phone to run tools first.
  final String? text;

  /// What the agent wrote to be said aloud (one or two natural sentences), when it did.
  final String? spoken;
  final List<ToolCall> calls;
  final bool planSaved;
  final List<Artifact> artifacts;

  /// Set when the agent saved a new strategy version in this request (review mode).
  final StrategyUpdate? strategyUpdate;

  bool get wantsTools => text == null && calls.isNotEmpty;

  factory ChatAnswer.fromJson(Map<String, Object?> j) {
    final type = j['type'];
    final artifacts = [
      for (final a in (j['artifacts'] as List? ?? const []))
        Artifact.fromJson(Map<String, Object?>.from(a as Map)),
    ];
    final update = j['strategy_update'] is Map
        ? StrategyUpdate.fromJson(
            Map<String, Object?>.from(j['strategy_update'] as Map),
          )
        : null;
    if (type == 'text') {
      return ChatAnswer(
        conversationId: j['conversation_id'] as String,
        text: j['text'] as String,
        spoken: j['spoken'] as String?,
        planSaved: j['plan_saved'] == true,
        artifacts: artifacts,
        strategyUpdate: update,
      );
    }
    if (type == 'tool_calls') {
      return ChatAnswer(
        conversationId: j['conversation_id'] as String,
        calls: [
          for (final c in (j['calls'] as List))
            ToolCall.fromJson(Map<String, Object?>.from(c as Map)),
        ],
        planSaved: j['plan_saved'] == true,
        artifacts: artifacts,
        strategyUpdate: update,
      );
    }
    throw AgentException('bad_response');
  }
}

class PlanTask {
  const PlanTask({
    required this.title,
    required this.minutes,
    this.firstStep,
    this.instructions = const [],
    this.links = const [],
    this.startTime,
  });

  final String title;
  final int minutes;
  final String? firstStep;
  final List<String> instructions;
  final List<String> links;
  final String? startTime;

  factory PlanTask.fromJson(Map<String, Object?> j) => PlanTask(
    title: j['title'] as String,
    minutes: (j['minutes'] as num).toInt(),
    firstStep: j['first_step'] as String?,
    instructions: [
      for (final s in (j['instructions'] as List? ?? const [])) s as String,
    ],
    links: [for (final s in (j['links'] as List? ?? const [])) s as String],
    startTime: j['start_time'] as String?,
  );
}

class PlanLimit {
  const PlanLimit({required this.app, required this.minutesPerDay});

  final String app;
  final int minutesPerDay;

  factory PlanLimit.fromJson(Map<String, Object?> j) => PlanLimit(
    app: j['app'] as String,
    minutesPerDay: (j['minutes_per_day'] as num).toInt(),
  );
}

class SavedPlan {
  const SavedPlan({
    required this.date,
    required this.status,
    required this.tasks,
    required this.limits,
    this.wake,
    this.sleep,
    this.note,
  });

  final String date;
  final String status;
  final List<PlanTask> tasks;
  final List<PlanLimit> limits;
  final String? wake;
  final String? sleep;
  final String? note;

  factory SavedPlan.fromJson(Map<String, Object?> j) {
    final data = Map<String, Object?>.from(j['data'] as Map);
    return SavedPlan(
      date: j['date'] as String,
      status: j['status'] as String,
      tasks: [
        for (final t in (data['tasks'] as List? ?? const []))
          PlanTask.fromJson(Map<String, Object?>.from(t as Map)),
      ],
      limits: [
        for (final l in (data['limits'] as List? ?? const []))
          PlanLimit.fromJson(Map<String, Object?>.from(l as Map)),
      ],
      wake: data['wake'] as String?,
      sleep: data['sleep'] as String?,
      note: data['note'] as String?,
    );
  }
}

/// The settings the app asks for in its own screens (never in the chat).
class Profile {
  const Profile({
    this.wake,
    this.sleep,
    this.apps = const [],
    this.focus,
    this.name,
  });

  final String? wake; // HH:MM
  final String? sleep; // HH:MM
  final List<String> apps;
  final String? focus;

  /// First name, asked in the welcome slides.
  final String? name;

  factory Profile.fromJson(Map<String, Object?> j) => Profile(
    wake: j['wake'] as String?,
    sleep: j['sleep'] as String?,
    apps: [for (final a in (j['apps'] as List? ?? const [])) a as String],
    focus: j['focus'] as String?,
    name: j['name'] as String?,
  );

  Map<String, Object?> toJson() => {
    if (wake != null) 'wake': wake,
    if (sleep != null) 'sleep': sleep,
    'apps': apps,
    if (focus != null) 'focus': focus,
    if (name != null) 'name': name,
  };
}

class UsageRow {
  const UsageRow({required this.day, required this.app, required this.minutes});

  final String day; // YYYY-MM-DD
  final String app;
  final int minutes;

  Map<String, Object?> toJson() => {'day': day, 'app': app, 'minutes': minutes};
}

class AttachResult {
  const AttachResult({
    required this.documentId,
    required this.name,
    required this.kind,
    required this.readBy,
  });

  final String documentId;
  final String name;
  final String kind; // pdf | text | image
  final String readBy; // text | vision

  factory AttachResult.fromJson(Map<String, Object?> j) => AttachResult(
    documentId: j['document_id'] as String,
    name: j['name'] as String,
    kind: j['kind'] as String,
    readBy: (j['read_by'] as String?) ?? 'text',
  );
}

class NudgeAnswer {
  const NudgeAnswer({required this.text, this.task});

  final String text;
  final String? task;
}

/// The user's day ends at 05:00, not midnight: at 01:00 it is still the evening of the day before, so planning then
/// plans the day that is about to start, and the Today list still shows the day that is ending.
const dayCutoffHour = 5;

DateTime logicalDay(DateTime now) {
  final d = now.hour < dayCutoffHour
      ? now.subtract(const Duration(hours: dayCutoffHour))
      : now;
  return DateTime(d.year, d.month, d.day);
}

/// One night of phone use, measured on the phone: when it went quiet and when it was picked up again. Not sleep.
class PhoneNight {
  const PhoneNight({required this.night, required this.down, this.up});

  final String night; // the evening's date
  final String down; // HH:MM
  final String? up;

  Map<String, Object?> toJson() => {'night': night, 'down': down, 'up': ?up};
}

/// Minutes after the evening's 18:00, so 23:30 < 01:10 < 03:00 compare the way a night runs.
int nightMinutes(String hhmm) {
  final m = int.parse(hhmm.substring(0, 2)) * 60 + int.parse(hhmm.substring(3));
  return (m - 18 * 60 + 1440) % 1440;
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// A new strategy version the agent saved, with what changed (the "Strategy updated" card).
class StrategyUpdate {
  const StrategyUpdate({required this.version, required this.changes});

  final int version;
  final List<String> changes;

  factory StrategyUpdate.fromJson(Map<String, Object?> j) => StrategyUpdate(
    version: (j['version'] as num).toInt(),
    changes: [for (final c in (j['changes'] as List? ?? const [])) c as String],
  );
}

/// What Lify learned about how to plan for this user (one version; every version is kept on the server).
class Strategy {
  const Strategy({
    required this.version,
    required this.forDate,
    this.limits = const [],
    this.maxTasks,
    this.bufferPct,
    this.bestWindow,
    this.riskWindows = const [],
    this.rules = const [],
    this.changes = const [],
    this.evidence = const [],
  });

  final int version;
  final String forDate;
  final List<({String app, int minutes, String? why})> limits;
  final int? maxTasks;
  final int? bufferPct;
  final String? bestWindow;
  final List<String> riskWindows;
  final List<String> rules;
  final List<String> changes;
  final List<String> evidence;

  static List<String> _texts(Object? v) => [
    for (final s in (v as List? ?? const [])) s as String,
  ];

  factory Strategy.fromJson(Map<String, Object?> j) {
    final style = Map<String, Object?>.from(
      (j['plan_style'] as Map?) ?? const {},
    );
    return Strategy(
      version: (j['version'] as num).toInt(),
      forDate: j['for_date'] as String,
      limits: [
        for (final l in (j['limits'] as List? ?? const []))
          (
            app: (l as Map)['app'] as String,
            minutes: (l['minutes'] as num).toInt(),
            why: l['why'] as String?,
          ),
      ],
      maxTasks: (style['max_tasks'] as num?)?.toInt(),
      bufferPct: (style['buffer_pct'] as num?)?.toInt(),
      bestWindow: style['best_window'] as String?,
      riskWindows: _texts(j['risk_windows']),
      rules: _texts(j['rules']),
      changes: _texts(j['changes']),
      evidence: _texts(j['evidence']),
    );
  }
}

/// One nudge style in the experiments: how often it was sent, how often the user then left the app, and the chance
/// (Thompson sampling) that it is the best style.
class ArmResult {
  const ArmResult({
    required this.arm,
    required this.label,
    required this.tried,
    required this.left,
    this.probBest = 0,
  });

  final String arm; // task | cost | goal
  final String label;
  final int tried;
  final int left;
  final double probBest;

  factory ArmResult.fromJson(Map<String, Object?> j) => ArmResult(
    arm: j['arm'] as String,
    label: j['label'] as String,
    tried: (j['tried'] as num).toInt(),
    left: (j['left'] as num).toInt(),
    probBest: (j['prob_best'] as num?)?.toDouble() ?? 0,
  );
}

/// The totals of the experiments (see the server's action "experiments").
class ExperimentResults {
  const ExperimentResults({
    required this.events,
    required this.days,
    required this.arms,
    this.best,
    this.apps = const [],
    this.demoEvents = 0,
    this.policy,
    this.contexts = const [],
    this.log = const [],
  });

  final int events;
  final int days;
  final List<ArmResult> arms;
  final String? best;
  final List<String> apps; // most hits first
  final int demoEvents;
  final PolicyEvaluation? policy;
  final List<ContextResult> contexts;
  final List<LabEntry> log;

  String labelOf(String arm) =>
      arms.where((a) => a.arm == arm).firstOrNull?.label ?? arm;

  factory ExperimentResults.fromJson(Map<String, Object?> j) =>
      ExperimentResults(
        events: (j['events'] as num).toInt(),
        days: (j['days'] as num).toInt(),
        arms: [
          for (final a in (j['arms'] as List? ?? const []))
            ArmResult.fromJson(Map<String, Object?>.from(a as Map)),
        ],
        best: j['best'] as String?,
        apps: [
          for (final a in (j['by_app'] as List? ?? const []))
            (a as Map)['app'] as String,
        ],
        demoEvents: (j['demo_events'] as num?)?.toInt() ?? 0,
        policy: j['policy'] is Map
            ? PolicyEvaluation.fromJson(
                Map<String, Object?>.from(j['policy'] as Map),
              )
            : null,
        contexts: [
          for (final c in (j['contexts'] as List? ?? const []))
            ContextResult.fromJson(Map<String, Object?>.from(c as Map)),
        ],
        log: [
          for (final e in (j['log'] as List? ?? const []))
            LabEntry.fromJson(Map<String, Object?>.from(e as Map)),
        ],
      );

  /// The card's sentence, built from the numbers only (never from the model): the sample sizes are always in it.
  String get headline {
    final tested = arms.where((a) => a.tried > 0).toList();
    final what = apps.length == 1 ? apps.first : 'your limited apps';
    if (tested.isEmpty)
      return 'No limit hits yet. I start testing the next time you hit a limit.';
    final b = best == null ? null : arms.firstWhere((a) => a.arm == best);
    if (b == null) {
      return 'Testing ${tested.length} nudge style${tested.length == 1 ? '' : 's'} on $what. '
          'So far: ${tested.map((a) => '${a.label} ${a.left} of ${a.tried}').join(', ')}. Not enough to pick a winner yet.';
    }
    final others = tested.where((a) => a.arm != b.arm).toList()
      ..sort((x, y) => y.tried.compareTo(x.tried));
    final vs = others.isEmpty
        ? ''
        : ' vs ${others.first.left} of ${others.first.tried} for ${others.first.label}';
    final label = b.label[0].toUpperCase() + b.label.substring(1);
    return 'Tested ${tested.length} nudge styles on $what. $label work best: '
        'you left ${b.left} of ${b.tried} times$vs. Sending more of them.';
  }
}

/// Off-policy evaluation: Life's own choices against always sending one fixed style (an estimate).
class PolicyEvaluation {
  const PolicyEvaluation({
    required this.events,
    required this.lifeRate,
    this.bestFixedArm,
    this.bestFixed,
    this.random,
    this.lift,
    this.liftLow,
    this.liftHigh,
  });

  final int events;
  final double lifeRate;
  final String? bestFixedArm;
  final double? bestFixed;
  final double? random;
  final double? lift;
  final double? liftLow;
  final double? liftHigh;

  factory PolicyEvaluation.fromJson(Map<String, Object?> j) {
    final best = j['best_fixed'] as Map?;
    final interval = j['lift_interval'] as List?;
    double? d(Object? v) => (v as num?)?.toDouble();
    return PolicyEvaluation(
      events: (j['events'] as num).toInt(),
      lifeRate: (j['life_rate'] as num).toDouble(),
      bestFixedArm: best?['arm'] as String?,
      bestFixed: d(best?['estimate']),
      random: d(j['random']),
      lift: d(j['lift']),
      liftLow: interval == null ? null : d(interval[0]),
      liftHigh: interval == null ? null : d(interval[1]),
    );
  }
}

/// Which style leads for one app at one time of day.
class ContextResult {
  const ContextResult({
    required this.app,
    required this.band,
    required this.hits,
    this.leading,
  });

  final String app;
  final String band;
  final int hits;
  final String? leading;

  factory ContextResult.fromJson(Map<String, Object?> j) => ContextResult(
    app: j['app'] as String,
    band: j['band'] as String,
    hits: (j['hits'] as num).toInt(),
    leading: j['leading'] as String?,
  );
}

/// One nudge in the lab notebook: what was sent, why that style, and what the user did next.
class LabEntry {
  const LabEntry({
    required this.day,
    required this.time,
    required this.app,
    required this.arm,
    required this.label,
    required this.explore,
    required this.left,
    required this.minutesAfter,
    this.band,
    this.propensity,
    this.message,
    this.demo = false,
  });

  final String day;
  final String time;
  final String app;
  final String? band;
  final String arm;
  final String label;
  final bool explore;
  final double? propensity;
  final String? message;
  final bool left;
  final double minutesAfter;
  final bool demo;

  factory LabEntry.fromJson(Map<String, Object?> j) => LabEntry(
    day: j['day'] as String,
    time: j['time'] as String,
    app: j['app'] as String,
    band: j['band'] as String?,
    arm: j['arm'] as String,
    label: j['label'] as String,
    explore: j['explore'] == true,
    propensity: (j['propensity'] as num?)?.toDouble(),
    message: j['message'] as String?,
    left: j['left'] == true,
    minutesAfter: (j['minutes_after'] as num?)?.toDouble() ?? 0,
    demo: j['demo'] == true,
  );
}

/// One event from the phone's calendar.
class CalendarEntry {
  const CalendarEntry({
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.busy = true,
  });

  final String title;
  final String start; // HH:MM
  final String end; // HH:MM
  final bool allDay;
  final bool busy;

  Map<String, Object?> toJson() => {
    'title': title,
    'start': start,
    'end': end,
    if (allDay) 'all_day': true,
    if (!busy) 'free': true,
  };
}
