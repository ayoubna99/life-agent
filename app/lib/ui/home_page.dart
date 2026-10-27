import 'package:flutter/material.dart';

import '../agent/models.dart';
import '../app_services.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_page.dart';
import '../device/next_task.dart';
import '../device/stores.dart';
import '../platform/services.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.services});

  final AppServices services;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  AppServices get s => widget.services;

  List<LocalTask> _tasks = [];
  bool _tomorrowPlanned = false;
  bool _todayReady = false;
  Profile _profile = const Profile();
  bool _profileLoaded = false;
  bool _usageOk = true;
  String? _offline;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    s.syncWatcher();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final tasks = await s.tasks.forDate(s.today);
    final usageOk = await s.native.hasUsageAccess().catchError((_) => false);
    if (mounted) {
      setState(() {
        _tasks = tasks;
        _usageOk = usageOk;
      });
    }
    try {
      final profile = await s.api.profile();
      final tomorrow = await s.api.plan(s.tomorrow);
      final today = await s.api.plan(s.today);
      if (mounted) {
        setState(() {
          _profile = profile;
          _profileLoaded = true;
          _tomorrowPlanned = tomorrow != null;
          _todayReady = today != null;
          _offline = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _offline = 'Offline: showing what is on this phone.');
      }
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hour = s.now().hour;
    final evening = hour >= 17;
    final next = nextTask(_tasks, s.now());
    return Scaffold(
      appBar: AppBar(
        title: const Text('Life'),
        actions: [
          IconButton(
            key: const Key('settings'),
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_offline != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_offline!, style: theme.textTheme.bodySmall),
              ),
            if (_needsSetup)
              _Banner(
                key: const Key('setup'),
                icon: Icons.tune,
                text:
                    'Tell me when you sleep and which apps distract you, so I can plan for you.',
                action: 'Set up',
                onTap: _openSettings,
              ),
            if (!_usageOk)
              _Banner(
                key: const Key('usage-banner'),
                icon: Icons.insights_outlined,
                text:
                    'Allow "Usage access" so I can plan with your real screen time.',
                action: 'Allow',
                onTap: s.native.openUsageAccessSettings,
              ),
            if (_todayReady && _tasks.isEmpty)
              _Banner(
                key: const Key('today-ready'),
                icon: Icons.wb_sunny_outlined,
                text: 'Good morning. Your plan for today is ready.',
                action: 'Start my day',
                onTap: () => _openChat(
                  'Start my day',
                  s.executeChat,
                  first: 'Apply today\'s plan.',
                ),
              ),
            if (next != null)
              Card(
                key: const Key('next'),
                color: theme.colorScheme.primaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: Text('Next: ${next.title}'),
                  subtitle: Text(
                    [
                      '${next.startTime != null ? '${next.startTime} · ' : ''}${next.minutes} min',
                      if (next.firstStep != null)
                        'First step: ${next.firstStep}',
                    ].join('\n'),
                  ),
                  isThreeLine: next.firstStep != null,
                  trailing: TextButton(
                    key: const Key('next-done'),
                    onPressed: () async {
                      await s.tasks.setDone(next.id, true);
                      _refresh();
                    },
                    child: const Text('Done'),
                  ),
                ),
              ),
            Text('Today', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_tasks.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Nothing on your list yet. Plan tomorrow tonight, and in the morning I set up your day.',
                    key: const Key('empty'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            else
              for (final t in _tasks)
                _TaskTile(
                  task: t,
                  opener: s.opener,
                  onChanged: (v) async {
                    await s.tasks.setDone(t.id, v);
                    _refresh();
                  },
                ),
            const SizedBox(height: 16),
            // Tomorrow's tasks are not shown tonight: nothing to read before sleep. They appear in the morning.
            if (_tomorrowPlanned)
              Card(
                key: const Key('tomorrow'),
                child: const ListTile(
                  leading: Icon(Icons.bedtime_outlined),
                  title: Text('Tomorrow is planned. Rest now.'),
                  subtitle: Text('Your tasks show up in the morning.'),
                ),
              ),
            const SizedBox(height: 8),
            _Action(
              key: const Key('start'),
              icon: Icons.play_circle_outline,
              title: 'Start my day',
              subtitle: 'I set up your tasks, limits and reminders',
              highlight: !evening,
              onTap: () => _openChat(
                'Start my day',
                s.executeChat,
                first: 'Apply today\'s plan.',
              ),
            ),
            _Action(
              key: const Key('plan'),
              icon: Icons.edit_calendar_outlined,
              title: 'Plan tomorrow',
              subtitle: 'Talk it through, I estimate the times',
              highlight: evening,
              onTap: () => _openChat(
                'Plan tomorrow',
                s.planningChat,
                hint: 'What do you want to do tomorrow?',
              ),
            ),
            _Action(
              key: const Key('review'),
              icon: Icons.fact_check_outlined,
              title: 'Review my day',
              subtitle: 'What worked, and an adapted plan for tomorrow',
              onTap: () => _openChat(
                'Review my day',
                s.reviewChat,
                first: 'Review my day.',
              ),
            ),
            const SizedBox(height: 16),
            Text('Test', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('test-next'),
                  onPressed: () => _say(s.testNextTask),
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('Next task (test)'),
                ),
                OutlinedButton.icon(
                  key: const Key('test-card'),
                  onPressed: () => _say(s.testNudgeCard),
                  icon: const Icon(Icons.layers_outlined),
                  label: const Text('Nudge card (test)'),
                ),
              ],
            ),
            const SizedBox(height: 24),
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
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
              ),
            ),
            TextButton(onPressed: onTap, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
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
    return Card(
      color: highlight ? theme.colorScheme.primaryContainer : null,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.opener,
    required this.onChanged,
  });

  final LocalTask task;
  final LinkOpener opener;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (task.firstStep != null) 'First step: ${task.firstStep}',
      for (final i in task.instructions) '• $i',
    ];
    final when = task.startTime != null ? '${task.startTime} · ' : '';
    return Card(
      child: ExpansionTile(
        key: Key('task-${task.title}'),
        leading: Checkbox(
          key: Key('check-${task.title}'),
          value: task.done,
          onChanged: (v) => onChanged(v ?? false),
        ),
        title: Text(
          task.title,
          style: TextStyle(
            decoration: task.done ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Text('$when${task.minutes} min'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final d in details)
            Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(d)),
          for (final l in task.links)
            TextButton.icon(
              onPressed: () => opener.open(l),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open material'),
            ),
        ],
      ),
    );
  }
}
