import 'package:flutter/material.dart';

import '../agent/models.dart';
import '../app_services.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_page.dart';
import '../device/next_task.dart';
import '../device/stores.dart';
import '../onboarding/onboarding_store.dart';
import '../platform/native.dart';
import '../platform/services.dart';
import 'motion.dart';
import 'settings_page.dart';
import 'task_page.dart';
import '../platform/experiment_settings.dart';
import 'learning.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.services});

  final AppServices services;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  AppServices get s => widget.services;

  final _scroll = ScrollController();
  List<LocalTask> _tasks = [];
  bool _tomorrowPlanned = false;
  bool _todayReady = false;
  Profile _profile = const Profile();
  bool _profileLoaded = false;
  bool _usageOk = true;
  int? _screenToday;
  String? _name;
  String? _offline;
  List<Strategy> _strategies = [];
  ExperimentResults? _results;
  ExperimentSettings _experiments = const ExperimentSettings();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    launchActionPing.addListener(_openFromNotification);
    _refresh();
    s.syncWatcher();
    s.syncNights();
    _loadShift();
    // opened by an alarm or the evening reminder: go to that screen even if the server cannot be reached
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _openFromNotification(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    launchActionPing.removeListener(_openFromNotification);
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      s.syncNights();
      _loadShift();
      _openFromNotification(); // an alarm or the evening reminder brought the app to the front
    }
  }

  NightShift? _shift;

  Future<void> _loadShift({bool force = false}) async {
    try {
      final shift = force
          ? await s.api.nightShift()
          : await s.syncNightShift() ?? _shift;
      if (mounted && shift != null) setState(() => _shift = shift);
    } catch (_) {
      // the card says the first night shift runs tonight
    }
  }

  Future<void> _refresh() async {
    final tasks = await s.tasks.forDate(s.today);
    final usageOk = await s.native.hasUsageAccess().catchError((_) => false);
    final name = await s.onboarding.name();
    int? screen;
    if (usageOk) {
      try {
        // screen time is counted from midnight, by the clock (the plan's day runs until 05:00, screen time does not)
        final rows = await s.native.usageSummary(days: 1);
        final midnight = isoDate(DateTime.now());
        screen = rows
            .where((r) => r.day == midnight)
            .fold<int>(0, (sum, r) => sum + r.minutes);
      } catch (_) {
        // no number today: the tile says so
      }
    }
    if (mounted) {
      setState(() {
        _tasks = tasks;
        _usageOk = usageOk;
        _screenToday = screen;
        _name = name;
      });
    }
    try {
      final profile = await s.api.profile();
      final tomorrow = await s.api.plan(s.tomorrow);
      final today = await s.api.plan(s.today);
      // a plan goes on the phone as soon as it exists (alarms set the night before, not in the morning)
      await s.applyPlan(today);
      await s.applyPlan(tomorrow);
      _todayOnPhone = today != null && await s.planApplier.applied(today);
      if (mounted) {
        setState(() {
          _profile = profile;
          _profileLoaded = true;
          _tomorrowPlanned = tomorrow != null;
          _todayReady = today != null;
          if (profile.name != null && profile.name!.isNotEmpty) {
            _name = profile.name;
          }
          _offline = null;
        });
      }
      s.syncWatcher(distracting: profile.apps, sleep: profile.sleep);
      _openFromNotification();
    } catch (e) {
      if (mounted) {
        setState(() => _offline = 'Offline: showing what is on this phone.');
      }
      return;
    }
    await _refreshLearning();
  }

  /// The evening reminder opens the app straight on "Plan tomorrow".
  Future<void> _openFromNotification() async {
    String? action;
    try {
      action = await s.native.takeLaunchAction();
    } catch (_) {}
    if (!mounted || action == null) return;
    if (action == 'plan') _planTomorrow();
    if (action == 'pull') {
      // "Pull me out" on a nudge: Life opens on what matters next
      final next = nextTask(await s.tasks.forDate(s.today), s.now());
      if (!mounted) return;
      if (next != null) {
        _openTask(next);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You\'re out. Good call.')),
        );
      }
    }
    if (action.startsWith('task:')) {
      final id = action.substring(5);
      final task = (await s.tasks.forDate(
        s.today,
      )).where((t) => t.id == id).firstOrNull;
      try {
        await s.native.stopAlarmSound();
      } catch (_) {}
      if (task != null && mounted) _openTask(task, ringing: true);
    }
  }

  /// The task's own screen: its first step, what was decided, its steps, links, PDFs and pictures.
  Future<void> _openTask(LocalTask task, {bool ringing = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskPage(
          task: task,
          opener: s.opener,
          ringing: ringing,
          onDone: () => s.tasks.setDone(task.id, true),
        ),
      ),
    );
    _refresh();
  }

  /// The strategy versions and the experiment totals: extras, so a failure here never marks the app offline.
  Future<void> _refreshLearning() async {
    final settings = await s.experimentSettings.load();
    List<Strategy> strategies = _strategies;
    ExperimentResults? results = _results;
    try {
      strategies = (await s.api.strategy()).history;
    } catch (_) {}
    if (settings.enabled) {
      try {
        results = await s.api.experiments(today: s.today);
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _experiments = settings;
        _strategies = strategies;
        _results = results;
      });
    }
  }

  Future<void> _enableExperiments() async {
    await s.experimentSettings.save(_experiments.copyWith(enabled: true));
    await s.syncWatcher(distracting: _profile.apps);
    await _refreshLearning();
  }

  void _openStrategy() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => StrategyPage(history: _strategies)),
  );

  bool get _needsSetup =>
      _profileLoaded && (_profile.wake == null || _profile.sleep == null);

  Future<void> _openChat(
    String title,
    Future<ChatController> Function(Profile) build, {
    String? first,
    String hint = 'Message',
  }) async {
    final controller = await build(_profile);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          title: title,
          controller: controller,
          opener: s.opener,
          firstMessage: first,
          hint: hint,
        ),
      ),
    );
    controller.dispose();
    _refresh();
  }

  bool _todayOnPhone = false;

  void _startDay() => _openChat(
    'Start my day',
    s.executeChat,
    first: _todayOnPhone
        ? 'Apply today\'s plan. Its tasks and alarms are already on the phone since last night: only set the app limits.'
        : 'Apply today\'s plan.',
  );

  void _planTomorrow() => _openChat(
    'Plan tomorrow',
    s.planningChat,
    hint: 'What do you want to do tomorrow?',
  );

  void _reviewDay() =>
      _openChat('Review my day', s.reviewChat, first: 'Review my day.');

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(services: s, profile: _profile),
      ),
    );
    _refresh();
  }

  Future<void> _say(Future<String> Function() action) async {
    final text = await action();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
  }

  Future<void> _setDone(LocalTask t, bool done) async {
    await s.tasks.setDone(t.id, done);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = s.now();
    final hour = now.hour;
    final evening = hour >= 17;
    final next = nextTask(_tasks, now);
    final done = _tasks.where((t) => t.done).length;

    final children = <Widget>[
      if (_offline != null)
        _Pill(text: _offline!, icon: Icons.cloud_off_rounded),
      if (_needsSetup)
        _Banner(
          key: const Key('setup'),
          icon: Icons.tune_rounded,
          text:
              'Tell me when you sleep and which apps distract you, so I can plan for you.',
          action: 'Set up',
          onTap: _openSettings,
        ),
      if (!_usageOk)
        _Banner(
          key: const Key('usage-banner'),
          icon: Icons.insights_rounded,
          text:
              'Allow "Usage access" so I can plan with your real screen time.',
          action: 'Allow',
          onTap: s.native.openUsageAccessSettings,
        ),
      if (_todayReady && _tasks.isEmpty)
        _SceneCard(
          key: const Key('today-ready'),
          image: 'morning_card',
          kicker: 'Good morning',
          title: 'Your plan for today is ready.',
          actionLabel: 'Start my day',
          onAction: _startDay,
        ),
      _StatsRow(
        done: done,
        total: _tasks.length,
        screenMinutes: _usageOk ? _screenToday : null,
      ),
      if (next != null)
        AnimatedSwitcher(
          duration: Motion.medium,
          switchInCurve: Motion.curve,
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0.08, 0),
                end: Offset.zero,
              ).animate(a),
              child: c,
            ),
          ),
          child: _NextCard(
            key: ValueKey('next-${next.id}'),
            task: next,
            onDone: () => _setDone(next, true),
          ),
        )
      else if (_tasks.isNotEmpty)
        const _AllDone(),
      _SectionTitle(
        title: 'Today',
        trailing: _tasks.isEmpty ? null : '$done of ${_tasks.length} done',
      ),
      if (_tasks.isEmpty)
        const _EmptyToday()
      else
        _Timeline(
          tasks: _tasks,
          next: next,
          opener: s.opener,
          onChanged: _setDone,
          onOpen: _openTask,
        ),
      // Tomorrow's tasks are not shown tonight: nothing to read before sleep. They appear in the morning.
      if (_tomorrowPlanned)
        const _SceneCard(
          key: Key('tomorrow'),
          image: 'night_card',
          kicker: 'Tonight',
          title: 'Tomorrow is planned. Rest now.',
          subtitle: 'Your tasks show up in the morning.',
        ),
      const _SectionTitle(title: 'Lify is learning'),
      NightShiftCard(
        shift: _shift,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NightShiftPage(shift: _shift!),
          ),
        ),
      ),
      if (_strategies.isNotEmpty)
        StrategyCard(strategy: _strategies.first, onOpen: _openStrategy),
      ExperimentCard(
        enabled: _experiments.enabled,
        results: _results,
        onEnable: _enableExperiments,
        onOpenLab: _results == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LabNotebookPage(results: _results!),
                ),
              ),
      ),
      const _SectionTitle(title: 'Talk to Lify'),
      _LifyActions(
        evening: evening,
        onStart: _startDay,
        onPlan: _planTomorrow,
        onReview: _reviewDay,
      ),
      _TestTools(
        onNext: () => _say(s.testNextTask),
        onEvening: () => _say(s.testEvening),
        onCard: () => _say(() => s.testNudgeCard(distracting: _profile.apps)),
        onShift: () => _say(() async {
          final r = await s.testNightShift();
          await _loadShift(force: true);
          return r;
        }),
      ),
    ];

    return Scaffold(
      body: RefreshIndicator(
        color: Brand.coral,
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _Header(
                key: const Key('header'),
                scroll: _scroll,
                greeting: _greeting(hour),
                name: _name,
                date: _date(now),
                onSettings: _openSettings,
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              // a plain column (not lazy): the page is short, and everything on it is there at once
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: cascade(
                    [
                      for (final c in children)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: c,
                        ),
                    ],
                    start: const Duration(milliseconds: 80),
                    step: const Duration(milliseconds: 60),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      backgroundColor: theme.colorScheme.surface,
    );
  }
}

String _greeting(int hour) => hour < 12
    ? 'Good morning'
    : hour < 18
    ? 'Good afternoon'
    : 'Good evening';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _date(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';

/// The sunrise picture under a big greeting; it drifts slower than the page when you scroll.
class _Header extends StatelessWidget {
  const _Header({
    super.key,
    required this.scroll,
    required this.greeting,
    required this.name,
    required this.date,
    required this.onSettings,
  });

  final ScrollController scroll;
  final String greeting;
  final String? name;
  final String date;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final top = MediaQuery.paddingOf(context).top;
    final surface = theme.colorScheme.surface;
    return SizedBox(
      height: 250 + top,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // the picture stays in place with its fades (it scrolls away with the page); the header fades out instead
          AnimatedBuilder(
            animation: scroll,
            builder: (context, child) {
              final offset = scroll.hasClients
                  ? scroll.offset.clamp(0.0, 200.0)
                  : 0.0;
              return Opacity(opacity: 1 - offset / 260, child: child);
            },
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 150,
                width: double.infinity,
                child: Image.asset(
                  'assets/images/home_header.webp',
                  fit: BoxFit.cover,
                  alignment: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          // the cream fades over the top of the picture, and again at the very bottom into the page
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  surface,
                  surface,
                  surface.withValues(alpha: 0),
                  surface.withValues(alpha: 0),
                  surface,
                ],
                stops: const [0, 0.42, 0.62, 0.86, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, top + 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SunMark(size: 30),
                    const SizedBox(width: 8),
                    Text(
                      date.toUpperCase(),
                      style: t.labelMedium?.copyWith(
                        letterSpacing: 1.2,
                        color: t.bodySmall?.color,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      key: const Key('settings'),
                      tooltip: 'Settings',
                      onPressed: onSettings,
                      style: IconButton.styleFrom(
                        backgroundColor: theme.cardTheme.color,
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      icon: const Icon(Icons.tune_rounded, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Reveal(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: name == null || name!.isEmpty
                              ? '$greeting.'
                              : '$greeting,\n',
                        ),
                        if (name != null && name!.isNotEmpty)
                          TextSpan(
                            text: '$name.',
                            style: const TextStyle(
                              color: Brand.coral,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                      ],
                    ),
                    style: t.displaySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: t.bodySmall?.color),
            const SizedBox(width: 6),
            Flexible(child: Text(text, style: t.bodySmall)),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.icon,
    required this.text,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              gradient: Brand.sunrise,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: Brand.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
          TextButton(onPressed: onTap, child: Text(action)),
        ],
      ),
    );
  }
}

/// A picture whose cream bottom runs into the card, with words on that cream part.
class _SceneCard extends StatelessWidget {
  const _SceneCard({
    super.key,
    required this.image,
    required this.kicker,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final String image;
  final String kicker;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF8EEDF),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Brand.dusk.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 960 / 520,
            child: Image.asset(
              'assets/images/$image.webp',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kicker.toUpperCase(),
                  style: t.labelMedium?.copyWith(
                    color: Brand.ember,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(title, style: t.headlineSmall?.copyWith(color: Brand.ink)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: t.bodyMedium?.copyWith(
                      color: const Color(0xFF6E5F55),
                    ),
                  ),
                ],
                if (actionLabel != null) ...[
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: onAction,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Two tiles: how much of today is done, and how long the phone has been used today.
class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.done,
    required this.total,
    required this.screenMinutes,
  });

  final int done;
  final int total;
  final int? screenMinutes;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Tile(
              key: const Key('stat-progress'),
              child: Row(
                children: [
                  ProgressRing(
                    value: total == 0 ? 0 : done / total,
                    size: 52,
                    stroke: 6,
                    child: Text(
                      total == 0 ? '–' : '$done',
                      style: t.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Today', style: t.labelSmall),
                        Text(
                          total == 0 ? 'No tasks' : '$done of $total',
                          style: t.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Tile(
              key: const Key('stat-screen'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.phone_iphone_rounded,
                        size: 16,
                        color: Brand.coral,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Screen time',
                          style: t.labelSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  screenMinutes == null
                      ? Text('Not allowed', style: t.titleMedium)
                      : CountUp(
                          value: screenMinutes!.toDouble(),
                          duration: const Duration(milliseconds: 900),
                          format: (v) => hoursAndMinutes(v.round()),
                          style: t.headlineSmall,
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: child,
    );
  }
}

/// The task to do now, big and warm, with its first step so starting feels small.
class _NextCard extends StatelessWidget {
  const _NextCard({super.key, required this.task, required this.onDone});

  final LocalTask task;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final meta = [
      if (task.startTime != null) task.startTime!,
      '${task.minutes} min',
    ].join(' · ');
    return Container(
      key: const Key('next'),
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
      decoration: BoxDecoration(
        gradient: Brand.sunrise,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Brand.coral.withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'UP NEXT',
                  style: t.labelSmall?.copyWith(
                    color: Brand.ink,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(meta, style: t.labelLarge?.copyWith(color: Brand.ink)),
            ],
          ),
          const SizedBox(height: 10),
          Text(task.title, style: t.headlineSmall?.copyWith(color: Brand.ink)),
          if (task.firstStep != null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.subdirectory_arrow_right_rounded,
                    size: 18,
                    color: Brand.ink,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'First step: ${task.firstStep}',
                    style: t.bodyMedium?.copyWith(color: Brand.ink),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('next-done'),
              onPressed: onDone,
              style: FilledButton.styleFrom(
                backgroundColor: Brand.ink,
                foregroundColor: Brand.cream,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
              ),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AllDone extends StatelessWidget {
  const _AllDone();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return _Tile(
      key: const Key('all-done'),
      child: Row(
        children: [
          const LifyOrb(size: 64),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('All done for today.', style: t.titleMedium),
                Text('The rest of the day is yours.', style: t.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              title,
              style: t.headlineSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: t.labelMedium?.copyWith(color: t.bodySmall?.color),
            ),
        ],
      ),
    );
  }
}

class _EmptyToday extends StatelessWidget {
  const _EmptyToday();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return _Tile(
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset(
              'assets/images/empty_list.webp',
              width: 76,
              height: 76,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Nothing on your list yet. Plan tomorrow tonight, and in the morning I set up your day.',
              key: const Key('empty'),
              style: t.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Today's tasks on a line, in order; tap one to see its steps, tap the circle to tick it off.
class _Timeline extends StatelessWidget {
  const _Timeline({
    required this.tasks,
    required this.next,
    required this.opener,
    required this.onChanged,
    required this.onOpen,
  });

  final List<LocalTask> tasks;
  final void Function(LocalTask) onOpen;
  final LocalTask? next;
  final LinkOpener opener;
  final void Function(LocalTask, bool) onChanged;

  @override
  Widget build(BuildContext context) {
    final sorted = [...tasks]
      ..sort((a, b) => (a.startTime ?? '99').compareTo(b.startTime ?? '99'));
    return Column(
      children: [
        for (var i = 0; i < sorted.length; i++)
          _TaskRow(
            task: sorted[i],
            isNext: sorted[i].id == next?.id,
            first: i == 0,
            last: i == sorted.length - 1,
            opener: opener,
            onChanged: (v) => onChanged(sorted[i], v),
            onOpen: () => onOpen(sorted[i]),
          ),
      ],
    );
  }
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    required this.task,
    required this.isNext,
    required this.first,
    required this.last,
    required this.opener,
    required this.onChanged,
    required this.onOpen,
  });

  final LocalTask task;
  final VoidCallback onOpen;
  final bool isNext;
  final bool first;
  final bool last;
  final LinkOpener opener;
  final ValueChanged<bool> onChanged;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final task = widget.task;
    final line = theme.colorScheme.outlineVariant;
    final details = [
      if (task.firstStep != null) 'First step: ${task.firstStep}',
      for (final i in task.instructions) '• $i',
    ];
    final when = task.startTime != null ? '${task.startTime} · ' : '';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // the line, with the tick circle on it
          SizedBox(
            width: 36,
            child: Column(
              children: [
                Container(
                  width: 2,
                  height: 14,
                  color: widget.first ? Colors.transparent : line,
                ),
                GestureDetector(
                  key: Key('check-${task.title}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onChanged(!task.done),
                  child: Semantics(
                    checked: task.done,
                    label: task.title,
                    child: AnimatedContainer(
                      duration: Motion.medium,
                      curve: Motion.spring,
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: task.done ? Brand.sunrise : null,
                        color: task.done ? null : theme.cardTheme.color,
                        border: Border.all(
                          color: task.done || widget.isNext
                              ? Brand.coral
                              : line,
                          width: 2,
                        ),
                      ),
                      child: AnimatedScale(
                        scale: task.done ? 1 : 0,
                        duration: Motion.medium,
                        curve: Motion.spring,
                        child: const Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: Brand.ink,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: widget.last ? Colors.transparent : line,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Pressable(
                key: Key('task-${task.title}'),
                scale: 0.98,
                onTap: () => setState(() => _open = !_open),
                child: AnimatedContainer(
                  duration: Motion.medium,
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  decoration: BoxDecoration(
                    color: theme.cardTheme.color,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: widget.isNext
                          ? Brand.coral.withValues(alpha: 0.6)
                          : line.withValues(alpha: 0.6),
                    ),
                  ),
                  child: AnimatedSize(
                    duration: Motion.medium,
                    curve: Motion.curve,
                    alignment: Alignment.topCenter,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AnimatedDefaultTextStyle(
                                    duration: Motion.medium,
                                    style: t.titleMedium!.copyWith(
                                      decoration: task.done
                                          ? TextDecoration.lineThrough
                                          : null,
                                      color: task.done
                                          ? t.bodySmall?.color
                                          : t.titleMedium?.color,
                                    ),
                                    child: Text(task.title),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '$when${task.minutes} min',
                                    style: t.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            if (details.isNotEmpty || task.links.isNotEmpty)
                              AnimatedRotation(
                                turns: _open ? 0.5 : 0,
                                duration: Motion.medium,
                                child: Icon(
                                  Icons.expand_more_rounded,
                                  color: t.bodySmall?.color,
                                ),
                              ),
                          ],
                        ),
                        if (_open) ...[
                          const SizedBox(height: 10),
                          for (final d in details)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(d, style: t.bodyMedium),
                            ),
                          for (final l in task.links)
                            TextButton.icon(
                              onPressed: () => widget.opener.open(l),
                              icon: const Icon(
                                Icons.open_in_new_rounded,
                                size: 18,
                              ),
                              label: const Text('Open material'),
                            ),
                          TextButton.icon(
                            key: Key('open-task-${task.title}'),
                            onPressed: widget.onOpen,
                            icon: const Icon(
                              Icons.fullscreen_rounded,
                              size: 18,
                            ),
                            label: const Text('Open task screen'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The three conversations with Lify. The one that fits the time of day is the big one.
class _LifyActions extends StatelessWidget {
  const _LifyActions({
    required this.evening,
    required this.onStart,
    required this.onPlan,
    required this.onReview,
  });

  final bool evening;
  final VoidCallback onStart;
  final VoidCallback onPlan;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final start = _ActionTile(
      key: const Key('start'),
      icon: Icons.wb_sunny_rounded,
      title: 'Start my day',
      subtitle: 'I set up your tasks, limits and reminders',
      highlight: !evening,
      onTap: onStart,
    );
    final plan = _ActionTile(
      key: const Key('plan'),
      icon: Icons.nightlight_round,
      title: 'Plan tomorrow',
      subtitle: 'Talk it through, I estimate the times',
      highlight: evening,
      onTap: onPlan,
    );
    final review = _ActionTile(
      key: const Key('review'),
      icon: Icons.auto_graph_rounded,
      title: 'Review my day',
      subtitle: 'What worked, and a better tomorrow',
      onTap: onReview,
    );
    final big = evening ? plan : start;
    final small = evening ? [review, start] : [plan, review];
    return Column(
      children: [
        big,
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: small[0]),
              const SizedBox(width: 12),
              Expanded(child: small[1]),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    if (highlight) {
      return Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          decoration: BoxDecoration(
            color: Brand.dusk,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              const LifyOrb(size: 76),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: t.headlineSmall?.copyWith(color: Brand.cream),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: t.bodyMedium?.copyWith(color: Brand.peach),
                    ),
                  ],
                ),
              ),
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  gradient: Brand.sunrise,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_forward_rounded,
                  color: Brand.ink,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                size: 20,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 12),
            Text(title, style: t.titleMedium),
            const SizedBox(height: 2),
            Text(subtitle, style: t.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// The checks for the demo phone: the next task's alarm, the nudge card, and the evening reminder.
class _TestTools extends StatelessWidget {
  const _TestTools({
    required this.onNext,
    required this.onCard,
    required this.onEvening,
    required this.onShift,
  });

  final VoidCallback onNext;
  final VoidCallback onCard;
  final VoidCallback onEvening;
  final VoidCallback onShift;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('TEST', style: t.labelSmall?.copyWith(letterSpacing: 1.4)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('test-next'),
              onPressed: onNext,
              icon: const Icon(Icons.alarm_rounded, size: 18),
              label: const Text('Task alarm (test)'),
            ),
            OutlinedButton.icon(
              key: const Key('test-evening'),
              onPressed: onEvening,
              icon: const Icon(Icons.nightlight_round, size: 18),
              label: const Text('Evening reminder (test)'),
            ),
            OutlinedButton.icon(
              key: const Key('test-card'),
              onPressed: onCard,
              icon: const Icon(Icons.layers_outlined, size: 18),
              label: const Text('Nudge card (test)'),
            ),
            OutlinedButton.icon(
              key: const Key('test-shift'),
              onPressed: onShift,
              icon: const Icon(Icons.biotech_rounded, size: 18),
              label: const Text('Night shift (test)'),
            ),
          ],
        ),
      ],
    );
  }
}
