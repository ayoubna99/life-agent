import 'package:flutter/material.dart';

import '../agent/models.dart';
import 'motion.dart';
import 'theme.dart';

/// How Lify adapts: the newest strategy version and what it changed last. Tap to see every version.
class StrategyCard extends StatelessWidget {
  const StrategyCard({super.key, required this.strategy, required this.onOpen});

  final Strategy strategy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    return Pressable(
      key: const Key('strategy-card'),
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.all(18),
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
            Row(
              children: [
                _Badge('Strategy v${strategy.version}'),
                const Spacer(),
                Flexible(
                  child: Text(
                    'See how it changed',
                    style: t.labelMedium?.copyWith(color: Brand.ember),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Brand.ember,
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (strategy.changes.isEmpty)
              Text(
                'Kept as it was: not enough new data to change it.',
                style: t.bodyMedium,
              )
            else
              for (final c in strategy.changes) _Bullet(c),
            if (strategy.rules.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final r in strategy.rules) _Chip(r)],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The experiments: an opt-in offer, or the results so far with their sample sizes.
class ExperimentCard extends StatelessWidget {
  const ExperimentCard({
    super.key,
    required this.enabled,
    required this.results,
    required this.onEnable,
    this.onOpenLab,
  });

  final bool enabled;
  final ExperimentResults? results;
  final VoidCallback onEnable;

  /// Opens the lab notebook (every nudge, why, and what happened).
  final VoidCallback? onOpenLab;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (!enabled) {
      return Container(
        key: const Key('experiment-offer'),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Brand.dusk,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.science_rounded, color: Brand.peach, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Let Life test what works for you',
                    style: t.titleMedium?.copyWith(color: Brand.cream),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'When you hit a limit I send you a personal nudge in one of three styles: your next task, what the time costs you, or your own goal. '
              'I count how often you leave the app after each, show you the numbers, and send more of what works.',
              style: t.bodyMedium?.copyWith(color: Brand.peach),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: const Key('experiment-enable'),
              onPressed: onEnable,
              child: const Text('Turn it on'),
            ),
          ],
        ),
      );
    }
    final r = results;
    final maxTried = r == null || r.arms.isEmpty
        ? 1
        : r.arms.map((a) => a.tried).reduce((a, b) => a > b ? a : b);
    return Container(
      key: const Key('experiment-results'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Brand.dusk,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.science_rounded, color: Brand.peach, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'What works for you',
                  style: t.titleMedium?.copyWith(color: Brand.cream),
                ),
              ),
              const _Badge('Early signal', dark: true),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            r?.headline ??
                'No limit hits yet. I start testing the next time you hit a limit.',
            key: const Key('experiment-headline'),
            style: t.bodyLarge?.copyWith(color: Brand.cream),
          ),
          if (r != null && r.events > 0) ...[
            const SizedBox(height: 14),
            for (final a in r.arms)
              _ArmBar(
                arm: a,
                best: a.arm == r.best,
                maxTried: maxTried == 0 ? 1 : maxTried,
              ),
            if (r.policy != null) ...[
              const SizedBox(height: 4),
              PolicyLine(policy: r.policy!, labelOf: r.labelOf),
            ],
            if (r.contexts.any((c) => c.leading != null)) ...[
              const SizedBox(height: 10),
              for (final c
                  in r.contexts.where((c) => c.leading != null).take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${c.app} · ${c.band}: ${r.labelOf(c.leading!)} lead (${c.hits} hits)',
                    key: Key('context-${c.app}-${c.band}'),
                    style: t.labelMedium?.copyWith(color: Brand.cream),
                  ),
                ),
            ],
            if (onOpenLab != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('open-lab'),
                  onPressed: onOpenLab,
                  style: TextButton.styleFrom(
                    foregroundColor: Brand.peach,
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(Icons.menu_book_rounded, size: 18),
                  label: const Text('Open the lab notebook'),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              '${r.events} limit hit${r.events == 1 ? '' : 's'} over ${r.days} day${r.days == 1 ? '' : 's'}, one person. '
              'Not proof, and no health claims.${r.demoEvents > 0 ? ' ${r.demoEvents} from demo mode.' : ''}',
              style: t.bodySmall?.copyWith(
                color: Brand.peach.withValues(alpha: 0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ArmBar extends StatelessWidget {
  const _ArmBar({
    required this.arm,
    required this.best,
    required this.maxTried,
  });

  final ArmResult arm;
  final bool best;
  final int maxTried;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final rate = arm.tried == 0 ? 0.0 : arm.left / arm.tried;
    final label = arm.label[0].toUpperCase() + arm.label.substring(1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: t.labelLarge?.copyWith(
                    color: best ? Brand.coral : Brand.cream,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  arm.tried == 0
                      ? 'not tried yet'
                      : 'left ${arm.left} of ${arm.tried} · ${(arm.probBest * 100).round()}% likely best',
                  key: Key('arm-${arm.arm}'),
                  textAlign: TextAlign.end,
                  style: t.labelMedium?.copyWith(color: Brand.peach),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: rate),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutQuart,
              builder: (_, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 8,
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                color: best ? Brand.coral : Brand.peach.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _pct(double v) => '${(v * 100).round()}%';
String _pts(double v) => '${v >= 0 ? '+' : '−'}${(v.abs() * 100).round()}';

/// Life's own choices against the best fixed nudge, from off-policy evaluation, always with its interval.
class PolicyLine extends StatelessWidget {
  const PolicyLine({
    super.key,
    required this.policy,
    required this.labelOf,
    this.dark = true,
  });

  final PolicyEvaluation policy;
  final String Function(String) labelOf;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = policy;
    final fg = dark ? Brand.cream : Theme.of(context).colorScheme.onSurface;
    final soft = dark ? Brand.peach : t.bodySmall?.color;
    return Container(
      key: const Key('policy-line'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.07)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Life\'s choices: you left ${_pct(p.lifeRate)} of the time'
            '${p.bestFixed != null ? ' · always ${labelOf(p.bestFixedArm!)}: about ${_pct(p.bestFixed!)}' : ''}',
            style: t.labelLarge?.copyWith(color: fg),
          ),
          if (p.lift != null && p.liftLow != null) ...[
            const SizedBox(height: 4),
            Text(
              '${_pts(p.lift!)} points (90% range ${_pts(p.liftLow!)} to ${_pts(p.liftHigh!)}), off-policy estimate from ${p.events} nudges',
              style: t.bodySmall?.copyWith(color: soft),
            ),
          ],
        ],
      ),
    );
  }
}

/// Every nudge Lify sent: the words, why that style was picked (and how likely it was), and what the user did next.
class LabNotebookPage extends StatelessWidget {
  const LabNotebookPage({super.key, required this.results});

  final ExperimentResults results;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final r = results;
    return Scaffold(
      appBar: AppBar(title: const Text('Lab notebook')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: cascade([
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Brand.dusk,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'How Lify tests',
                  style: t.titleMedium?.copyWith(color: Brand.cream),
                ),
                const SizedBox(height: 6),
                Text(
                  'At each limit hit, code on your phone (not the AI) picks one of 3 nudge styles with contextual Thompson '
                  'sampling: for this app at this time of day, each style has a belief about how often you leave the app, '
                  'borrowed from your other moments until there is enough data. Muse Spark then writes the nudge from your plan '
                  'and goal. Your phone measures whether you left within 2 minutes, and the belief updates.',
                  style: t.bodyMedium?.copyWith(color: Brand.peach),
                ),
                if (r.policy != null) ...[
                  const SizedBox(height: 12),
                  PolicyLine(policy: r.policy!, labelOf: r.labelOf),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('Every nudge', style: t.headlineSmall),
          const SizedBox(height: 10),
          if (r.log.isEmpty)
            Text(
              'Nothing yet. The next limit hit starts the notebook.',
              style: t.bodyMedium,
            )
          else
            for (final (i, e) in r.log.indexed)
              _LabTile(key: Key('lab-$i'), e: e),
        ]),
      ),
    );
  }
}

class _LabTile extends StatelessWidget {
  const _LabTile({super.key, required this.e});

  final LabEntry e;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final why = e.explore
        ? 'Testing: picked with a ${e.propensity == null ? 'small' : _pct(e.propensity!)} chance'
        : 'Current best here${e.propensity == null ? '' : ' (${_pct(e.propensity!)} chance)'}';
    final mins = e.minutesAfter >= 1
        ? '${e.minutesAfter.round()} more min'
        : 'under a minute';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${e.time} · ${e.app}${e.band == null ? '' : ' · ${e.band}'}${e.demo ? ' · demo' : ''}',
                  style: t.labelMedium,
                ),
              ),
              _Badge(e.explore ? 'testing' : 'best so far'),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            e.angle != null
                ? 'Angle: ${e.angle!.replaceAll('_', ' ')}'
                : e.label[0].toUpperCase() + e.label.substring(1),
            style: t.titleSmall,
          ),
          Text(why, style: t.bodySmall),
          if (e.message != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: Brand.dusk,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '"${e.message}"',
                style: t.bodyMedium?.copyWith(
                  color: Brand.cream,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                e.left
                    ? Icons.check_circle_rounded
                    : Icons.replay_circle_filled_rounded,
                size: 18,
                color: e.left ? Brand.coral : t.bodySmall?.color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  e.pulled
                      ? 'You tapped Pull me out. This idea comes back, in new words.'
                      : e.left
                      ? 'You left the app. This idea gets picked more here.'
                      : 'You stayed $mins. This idea gets picked less here; trying others.',
                  style: t.bodyMedium,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The "Strategy updated" card in the chat, under the agent's reply.
class StrategyUpdateCard extends StatelessWidget {
  const StrategyUpdateCard({super.key, required this.update});

  final StrategyUpdate update;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      key: const Key('strategy-updated'),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: Brand.sunrise,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: Brand.ink,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Strategy updated · v${update.version}',
                  style: t.titleSmall?.copyWith(color: Brand.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (update.changes.isEmpty)
            Text(
              'Kept as it was: not enough data to change it yet.',
              style: t.bodyMedium?.copyWith(color: Brand.ink),
            )
          else
            for (final c in update.changes) _Bullet(c, color: Brand.ink),
        ],
      ),
    );
  }
}

/// Every strategy version, with the first one next to the newest (day 1 against today).
class StrategyPage extends StatelessWidget {
  const StrategyPage({super.key, required this.history});

  /// Newest first.
  final List<Strategy> history;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final first = history.isEmpty ? null : history.last;
    final now = history.isEmpty ? null : history.first;
    return Scaffold(
      appBar: AppBar(title: const Text('How Lify adapts')),
      body: history.isEmpty
          ? const Center(
              child: Text(
                'No strategy yet. It is made after your first evening review.',
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: cascade([
                if (first != null &&
                    now != null &&
                    first.version != now.version) ...[
                  Text('Then and now', style: t.headlineSmall),
                  const SizedBox(height: 10),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _Snapshot(
                            key: const Key('then'),
                            title: 'v${first.version} · ${first.forDate}',
                            s: first,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _Snapshot(
                            key: const Key('now'),
                            title: 'v${now.version} · ${now.forDate}',
                            s: now,
                            highlight: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                Text('Every version', style: t.headlineSmall),
                const SizedBox(height: 10),
                for (final s in history) _VersionTile(s: s),
              ]),
            ),
    );
  }
}

class _Snapshot extends StatelessWidget {
  const _Snapshot({
    super.key,
    required this.title,
    required this.s,
    this.highlight = false,
  });

  final String title;
  final Strategy s;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final fg = highlight ? Brand.ink : theme.colorScheme.onSurface;
    TextStyle? small = t.bodySmall?.copyWith(
      color: highlight ? Brand.ink.withValues(alpha: 0.75) : null,
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: highlight ? Brand.sunrise : null,
        color: highlight ? null : theme.cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: highlight
            ? null
            : Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.labelMedium?.copyWith(color: fg)),
          const SizedBox(height: 8),
          Text(
            s.maxTasks == null ? 'No task cap' : 'Max ${s.maxTasks} tasks',
            style: t.titleMedium?.copyWith(color: fg),
          ),
          if (s.bufferPct != null) Text('${s.bufferPct}% buffer', style: small),
          if (s.bestWindow != null) Text('Best: ${s.bestWindow}', style: small),
          const SizedBox(height: 6),
          for (final l in s.limits)
            Text(
              '${l.app} ${l.minutes} min',
              style: t.bodyMedium?.copyWith(color: fg),
            ),
          for (final w in s.riskWindows) Text('Watch $w', style: small),
        ],
      ),
    );
  }
}

class _VersionTile extends StatelessWidget {
  const _VersionTile({required this.s});

  final Strategy s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    return Container(
      key: Key('version-${s.version}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Badge('v${s.version}'),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'for ${s.forDate}',
                  style: t.labelMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (s.changes.isEmpty)
            Text('No change.', style: t.bodyMedium)
          else
            for (final c in s.changes) _Bullet(c),
          if (s.evidence.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Because', style: t.labelSmall),
            for (final e in s.evidence) Text(e, style: t.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 8),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color ?? Brand.coral,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(text, style: t.bodyMedium?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(text, style: Theme.of(context).textTheme.labelMedium),
  );
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.dark = false});

  final String text;
  final bool dark;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: dark ? Colors.white.withValues(alpha: 0.12) : Brand.peach,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: dark ? Brand.peach : Brand.ink,
        letterSpacing: 0.6,
      ),
    ),
  );
}

String _statusLabel(String s) => switch (s) {
  'kept' => 'kept',
  'rejected' => 'rejected',
  _ => 'testing',
};

/// The night shift on the home screen: Lify's theories about you and tomorrow's experiment. Tap for everything.
class NightShiftCard extends StatelessWidget {
  const NightShiftCard({super.key, required this.shift, this.onOpen});

  final NightShift? shift;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = shift;
    return Pressable(
      key: const Key('night-shift-card'),
      onTap: s == null ? null : onOpen,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Brand.dusk,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.biotech_rounded, color: Brand.peach, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Lify\'s theories about you',
                    style: t.titleMedium?.copyWith(color: Brand.cream),
                  ),
                ),
                if (s != null)
                  const Icon(Icons.chevron_right_rounded, color: Brand.peach),
              ],
            ),
            const SizedBox(height: 8),
            if (s == null)
              Text(
                'Every night Lify studies everything it knows about you, forms theories about what gets you off your phone, '
                'and writes tomorrow\'s experiment. The first night shift runs this evening.',
                style: t.bodyMedium?.copyWith(color: Brand.peach),
              )
            else ...[
              for (final th
                  in s.theories.where((x) => x.status != 'rejected').take(2))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TheoryLine(theory: th, dark: true),
                ),
              Text(
                '${s.angles.length} ideas and ${s.lineCount} fresh lines ready for ${s.day}'
                '${s.cut > 0 ? ' · the critic cut ${s.cut}' : ''}',
                style: t.bodySmall?.copyWith(color: Brand.peach),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TheoryLine extends StatelessWidget {
  const _TheoryLine({required this.theory, this.dark = false});

  final Theory theory;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = dark ? Brand.cream : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                theory.statement,
                style: t.bodyLarge?.copyWith(color: color),
              ),
            ),
            const SizedBox(width: 8),
            _Badge(
              '${_statusLabel(theory.status)} · ${(theory.confidence * 100).round()}%',
            ),
          ],
        ),
        if (theory.evidence.isNotEmpty)
          Text(
            'Checked on your data: ${theory.evidence}',
            style: t.bodySmall?.copyWith(color: dark ? Brand.peach : null),
          ),
        if (theory.overruled)
          Text(
            'Lify guessed "${theory.modelStatus}"; your results say "${_statusLabel(theory.status)}".',
            key: const Key('theory-overruled'),
            style: t.bodySmall?.copyWith(
              color: dark ? Brand.peach : null,
              fontStyle: FontStyle.italic,
            ),
          ),
      ],
    );
  }
}

/// Everything from the newest night shift: the theories (kept, testing, rejected), tomorrow's ideas with their lines
/// and results, and a short excerpt of how the open model reasoned about it.
class NightShiftPage extends StatelessWidget {
  const NightShiftPage({super.key, required this.shift});

  final NightShift shift;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final s = shift;
    return Scaffold(
      appBar: AppBar(title: const Text('Night shift')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: cascade([
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Brand.dusk,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Text(
              'Every night Muse Spark Open reads your whole history at once: every nudge, what you did next, your nights '
              'and plans. It proposes theories about what gets you off your phone, and when. It cannot grade them: code '
              'checks each one on your real results (the moments it is about, with the theory vs without) and gives the '
              'chance it is true. Then it writes tomorrow\'s lines to test them; a second pass, your inner skeptic, cuts '
              'the weak ones. During the day your phone picks the idea that works best for you right now and shows a line '
              'you have never seen.',
              style: t.bodyMedium?.copyWith(color: Brand.peach),
            ),
          ),
          if (s.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(s.notes, key: const Key('night-notes'), style: t.bodyLarge),
          ],
          const SizedBox(height: 20),
          Text('Theories', style: t.headlineSmall),
          const SizedBox(height: 10),
          for (final th in s.theories)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _TheoryLine(theory: th),
            ),
          const SizedBox(height: 12),
          Text('Ideas for ${s.day}', style: t.headlineSmall),
          const SizedBox(height: 10),
          for (final a in s.angles)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.cardTheme.color,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.name, style: t.titleSmall),
                  Text(
                    a.tried == 0
                        ? 'New: not tried yet'
                        : 'You left ${a.left} of ${a.tried} times',
                    style: t.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  for (final l in a.lines)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('"$l"', style: t.bodyMedium),
                    ),
                ],
              ),
            ),
          if (s.assumptions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Starting assumptions', style: t.headlineSmall),
            Text(
              'What Lify assumes about most people until it has your results. Not facts: worth about 3 nudges each, '
              'so your own results outweigh them within a day or two.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final a in s.assumptions)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· $a', style: t.bodyMedium),
              ),
          ],
          if (s.thinking != null) ...[
            const SizedBox(height: 12),
            ExpansionTile(
              key: const Key('night-thinking'),
              tilePadding: EdgeInsets.zero,
              title: const Text('How Lify thought about it'),
              subtitle: const Text(
                'The open model\'s own reasoning, an excerpt',
              ),
              children: [
                Text(
                  s.thinking!,
                  style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}
