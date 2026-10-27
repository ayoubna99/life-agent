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
    this.calls = const [],
    this.planSaved = false,
    this.artifacts = const [],
  });

  final String conversationId;

  /// The agent's words, or null when it asked the phone to run tools first.
  final String? text;
  final List<ToolCall> calls;
  final bool planSaved;
  final List<Artifact> artifacts;

  bool get wantsTools => text == null && calls.isNotEmpty;

  factory ChatAnswer.fromJson(Map<String, Object?> j) {
    final type = j['type'];
    final artifacts = [
      for (final a in (j['artifacts'] as List? ?? const []))
        Artifact.fromJson(Map<String, Object?>.from(a as Map)),
    ];
    if (type == 'text') {
      return ChatAnswer(
        conversationId: j['conversation_id'] as String,
        text: j['text'] as String,
        planSaved: j['plan_saved'] == true,
        artifacts: artifacts,
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
  const Profile({this.wake, this.sleep, this.apps = const [], this.focus});

  final String? wake; // HH:MM
  final String? sleep; // HH:MM
  final List<String> apps;
  final String? focus;

  factory Profile.fromJson(Map<String, Object?> j) => Profile(
    wake: j['wake'] as String?,
    sleep: j['sleep'] as String?,
    apps: [for (final a in (j['apps'] as List? ?? const [])) a as String],
    focus: j['focus'] as String?,
  );

  Map<String, Object?> toJson() => {
    if (wake != null) 'wake': wake,
    if (sleep != null) 'sleep': sleep,
    'apps': apps,
    if (focus != null) 'focus': focus,
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

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
