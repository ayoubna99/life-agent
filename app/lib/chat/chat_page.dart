import 'package:flutter/material.dart';

import '../agent/models.dart';
import '../platform/services.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'chat_controller.dart';
import 'messages.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.title,
    required this.controller,
    required this.opener,
    this.firstMessage,
    this.hint = 'Message',
  });

  final String title;
  final ChatController controller;
  final LinkOpener opener;

  /// Sent as soon as the screen opens (the morning run starts by itself).
  final String? firstMessage;
  final String hint;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _text = TextEditingController();
  final _scroll = ScrollController();

  ChatController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    final first = widget.firstMessage;
    if (first != null)
      WidgetsBinding.instance.addPostFrameCallback((_) => c.send(first));
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients)
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
    });
  }

  void _send() {
    final t = _text.text;
    _text.clear();
    c.send(t);
  }

  void _attachMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                c.attachPhoto(camera: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                c.attachPhoto(camera: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('PDF or text file'),
              onTap: () {
                Navigator.pop(ctx);
                c.attachDocument();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            LifyOrb(size: 44, talking: c.busy),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Lify', style: theme.textTheme.titleMedium),
                  Text(widget.title, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: c.messages.isEmpty && !c.busy
                ? Center(
                    key: const Key('welcome'),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const LifyOrb(size: 170),
                          const SizedBox(height: 16),
                          Text(
                            widget.title,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Type, or hold the microphone and talk.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).textTheme.bodySmall?.color,
                                ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const Key('messages'),
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: c.messages.length,
                    itemBuilder: (_, i) => Reveal(
                      key: ValueKey(c.messages[i]),
                      offset: const Offset(0, 14),
                      duration: Motion.medium,
                      child: _Bubble(
                        message: c.messages[i],
                        opener: widget.opener,
                      ),
                    ),
                  ),
          ),
          if (c.planSaved)
            Reveal(
              offset: const Offset(0, 20),
              child: Container(
                key: const Key('plan-saved'),
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  gradient: Brand.sunrise,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: Brand.ink),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Your plan is saved.',
                        style: TextStyle(
                          color: Brand.ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (c.status != null || c.busy)
            Padding(
              key: const Key('status'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  if (c.busy) const _TypingDots(key: Key('typing')),
                  if (c.busy) const SizedBox(width: 8),
                  if (c.status != null)
                    Expanded(
                      child: Text(c.status!, style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ),
          if (c.attachments.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final a in c.attachments)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        label: Text(a.name),
                        avatar: Icon(
                          a.kind == 'image' ? Icons.photo : Icons.description,
                          size: 18,
                        ),
                        onDeleted: () => c.removeAttachment(a),
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
              decoration: BoxDecoration(
                color: theme.cardTheme.color,
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: Brand.dusk.withValues(alpha: 0.06),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('attach'),
                    tooltip: 'Attach',
                    onPressed: c.busy || c.recording ? null : _attachMenu,
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('input'),
                      controller: _text,
                      enabled: !c.recording,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: c.recording ? 'Listening…' : widget.hint,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  _HoldToTalk(controller: c),
                  IconButton.filled(
                    key: const Key('send'),
                    tooltip: 'Send',
                    onPressed: c.busy || c.recording ? null : _send,
                    icon: const Icon(Icons.arrow_upward_rounded),
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

/// Press and hold to talk, let go to send, slide away to cancel. It listens from the moment the finger touches down.
class _HoldToTalk extends StatefulWidget {
  const _HoldToTalk({required this.controller});

  final ChatController controller;

  @override
  State<_HoldToTalk> createState() => _HoldToTalkState();
}

class _HoldToTalkState extends State<_HoldToTalk> {
  static const _cancelDistance = 90.0;
  Offset? _down;
  bool _willCancel = false;

  ChatController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = c.busy && !c.recording;
    final recording = c.recording;
    return Listener(
      key: const Key('mic'),
      onPointerDown: disabled
          ? null
          : (e) {
              _down = e.position;
              _willCancel = false;
              c.startListening();
            },
      onPointerMove: (e) {
        final start = _down;
        if (start == null) return;
        final away = (e.position - start).distance > _cancelDistance;
        if (away != _willCancel) setState(() => _willCancel = away);
      },
      onPointerUp: (_) {
        _down = null;
        c.stopListening(cancel: _willCancel);
        setState(() => _willCancel = false);
      },
      onPointerCancel: (_) {
        _down = null;
        c.stopListening(cancel: true);
        setState(() => _willCancel = false);
      },
      child: Tooltip(
        message: 'Hold to talk',
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.spring,
          width: recording ? 60 : 44,
          height: recording ? 60 : 44,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: disabled
                ? theme.colorScheme.surfaceContainerHighest
                : recording
                ? (_willCancel
                      ? theme.colorScheme.outline
                      : theme.colorScheme.error)
                : theme.colorScheme.secondaryContainer,
            boxShadow: recording && !_willCancel
                ? [
                    BoxShadow(
                      color: theme.colorScheme.error.withValues(alpha: 0.4),
                      blurRadius: 18,
                      spreadRadius: 4,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            _willCancel ? Icons.close : Icons.mic,
            color: recording
                ? theme.colorScheme.onError
                : theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.opener});

  final ChatMessage message;
  final LinkOpener opener;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = message.who == Who.user;
    final note = message.who == Who.note;
    final bg = note
        ? (message.error
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.surfaceContainerHighest)
        : mine
        ? theme.colorScheme.primary
        : theme.colorScheme.secondaryContainer;
    final fg = note
        ? (message.error
              ? theme.colorScheme.onErrorContainer
              : theme.colorScheme.onSurfaceVariant)
        : mine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.86,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: mine || note ? bg : theme.cardTheme.color,
            gradient: mine ? Brand.sunrise : null,
            border: mine || note
                ? null
                : Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(22),
              topRight: const Radius.circular(22),
              bottomLeft: Radius.circular(mine ? 22 : 6),
              bottomRight: Radius.circular(mine ? 6 : 22),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(message.text, style: TextStyle(color: fg)),
              for (final a in message.artifacts)
                _ArtifactCard(artifact: a, opener: opener),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({required this.artifact, required this.opener});

  final Artifact artifact;
  final LinkOpener opener;

  @override
  Widget build(BuildContext context) {
    final image = artifact.type == 'image';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (image)
              Image.network(
                artifact.url,
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 60,
                  child: Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            ListTile(
              key: Key('artifact-${artifact.title}'),
              leading: Icon(
                image ? Icons.image_outlined : Icons.picture_as_pdf_outlined,
              ),
              title: Text(artifact.title),
              subtitle: Text(
                image
                    ? 'Picture'
                    : artifact.type == 'pdf'
                    ? 'PDF'
                    : 'Document',
              ),
              trailing: const Icon(Icons.open_in_new),
              onTap: () async {
                final ok = await opener.open(artifact.url);
                if (!ok && context.mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open the file.')),
                  );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Three dots that bounce while Lify is thinking.
class _TypingDots extends StatefulWidget {
  const _TypingDots({super.key});

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Ambient.on(context) && !_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 30,
    height: 16,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < 3; i++)
            Transform.translate(
              offset: Offset(
                0,
                -4 *
                    Curves.easeInOut.transform(
                      (1 - ((_c.value - i * 0.15) % 1 * 2 - 1).abs()).clamp(
                        0,
                        1,
                      ),
                    ),
              ),
              child: Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: Brand.coral,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
