import 'package:flutter/material.dart';

import '../agent/models.dart';
import '../platform/services.dart';
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
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              key: const Key('messages'),
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: c.messages.length,
              itemBuilder: (_, i) =>
                  _Bubble(message: c.messages[i], opener: widget.opener),
            ),
          ),
          if (c.planSaved)
            Container(
              key: const Key('plan-saved'),
              width: double.infinity,
              color: theme.colorScheme.primaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Your plan is saved.')),
                ],
              ),
            ),
          if (c.status != null)
            Padding(
              key: const Key('status'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  if (c.busy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (c.busy) const SizedBox(width: 8),
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
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
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    key: const Key('mic'),
                    tooltip: c.recording ? 'Stop and send' : 'Talk',
                    onPressed: c.busy && !c.recording ? null : c.toggleVoice,
                    icon: Icon(
                      c.recording ? Icons.stop_circle : Icons.mic,
                      color: c.recording ? theme.colorScheme.error : null,
                    ),
                  ),
                  IconButton.filled(
                    key: const Key('send'),
                    tooltip: 'Send',
                    onPressed: c.busy || c.recording ? null : _send,
                    icon: const Icon(Icons.send),
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
        : theme.colorScheme.onSecondaryContainer;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.86,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
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
