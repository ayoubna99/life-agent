import 'package:flutter/material.dart';

import '../device/stores.dart';
import '../platform/services.dart';
import 'motion.dart';
import 'theme.dart';

/// What a link in a task points to, from its address (signed links to our own files end in .pdf, .png, ...).
enum LinkKind { pdf, image, web }

LinkKind linkKind(String url) {
  final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
  if (path.endsWith('.pdf')) return LinkKind.pdf;
  if (RegExp(r'\.(png|jpe?g|webp|gif)$').hasMatch(path)) return LinkKind.image;
  return LinkKind.web;
}

/// The task's own screen: everything decided in the chat, ready when its time comes. An in-app alarm opens it.
class TaskPage extends StatelessWidget {
  const TaskPage({
    super.key,
    required this.task,
    required this.opener,
    required this.onDone,
    this.ringing = false,
  });

  final LocalTask task;
  final LinkOpener opener;
  final Future<void> Function() onDone;

  /// Opened by its alarm (the header says "It's time").
  final bool ringing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final images = [
      for (final l in task.links)
        if (linkKind(l) == LinkKind.image) l,
    ];
    final files = [
      for (final l in task.links)
        if (linkKind(l) != LinkKind.image) l,
    ];
    return Scaffold(
      appBar: AppBar(),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('task-later'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Later'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  key: const Key('task-done'),
                  onPressed: task.done
                      ? null
                      : () async {
                          await onDone();
                          if (context.mounted) Navigator.of(context).pop();
                        },
                  icon: const Icon(Icons.check_rounded),
                  label: Text(task.done ? 'Done' : 'Mark as done'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: cascade([
          Text(
            (ringing ? 'It\'s time' : 'Your task').toUpperCase(),
            style: t.labelMedium?.copyWith(
              color: Brand.ember,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            task.title,
            key: const Key('task-title'),
            style: t.headlineLarge,
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (task.startTime != null) task.startTime!,
              '${task.minutes} min',
            ].join(' · '),
            style: t.titleMedium?.copyWith(color: t.bodySmall?.color),
          ),
          if (task.firstStep != null) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: Brand.sunrise,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.play_arrow_rounded, color: Brand.ink),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'START HERE',
                          style: t.labelSmall?.copyWith(
                            color: Brand.ink,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          task.firstStep!,
                          style: t.titleMedium?.copyWith(color: Brand.ink),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (task.notes != null) ...[
            const SizedBox(height: 18),
            const _Label('What we decided'),
            Text(task.notes!, key: const Key('task-notes'), style: t.bodyLarge),
          ],
          if (task.instructions.isNotEmpty) ...[
            const SizedBox(height: 18),
            const _Label('Steps'),
            for (final (i, step) in task.instructions.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Text('${i + 1}', style: t.labelLarge),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(step, style: t.bodyLarge),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (task.links.isNotEmpty) ...[
            const SizedBox(height: 18),
            const _Label('Your material'),
            for (final url in images)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Pressable(
                  onTap: () => opener.open(url),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.network(
                      url,
                      key: Key('task-image-$url'),
                      fit: BoxFit.cover,
                      height: 200,
                      width: double.infinity,
                      errorBuilder: (_, _, _) => _LinkCard(
                        kind: LinkKind.image,
                        url: url,
                        opener: opener,
                      ),
                    ),
                  ),
                ),
              ),
            for (final url in files)
              _LinkCard(kind: linkKind(url), url: url, opener: opener),
          ],
        ]),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.kind,
    required this.url,
    required this.opener,
  });

  final LinkKind kind;
  final String url;
  final LinkOpener opener;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final uri = Uri.tryParse(url);
    final name = Uri.decodeComponent(uri?.pathSegments.lastOrNull ?? url);
    final (icon, label) = switch (kind) {
      LinkKind.pdf => (Icons.picture_as_pdf_rounded, 'Study sheet (PDF)'),
      LinkKind.image => (Icons.image_rounded, 'Picture'),
      LinkKind.web => (
        Icons.public_rounded,
        uri?.host.replaceFirst('www.', '') ?? 'Link',
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        key: Key('task-link-$url'),
        onTap: () => opener.open(url),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.cardTheme.color,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: t.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      name,
                      style: t.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.open_in_new_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
