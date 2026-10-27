import 'package:flutter/material.dart';

import '../agent/models.dart';
import '../app_services.dart';
import '../platform/voice_settings.dart';

/// What the app asks in its own screens (never in the chat): when you wake and sleep, which apps pull you away,
/// what you are working towards. Saved on the server, so the agent already knows it.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.services,
    required this.profile,
  });

  final AppServices services;
  final Profile profile;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppServices get s => widget.services;

  late String? _wake = widget.profile.wake;
  late String? _sleep = widget.profile.sleep;
  late List<String> _apps = [...widget.profile.apps];
  late final _focus = TextEditingController(text: widget.profile.focus ?? '');
  bool _saving = false;
  String? _error;
  bool _usage = false;
  bool _notifications = false;
  bool _alarms = false;
  bool _overlay = false;
  VoiceSettings _voice = const VoiceSettings();
  List<SpeechVoice> _voices = [];

  @override
  void initState() {
    super.initState();
    _permissions();
    _loadVoice();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadVoice() async {
    final voice = await s.voiceSettings.load();
    final all = await s.speaker.voices();
    if (mounted)
      setState(() {
        _voice = voice;
        _voices = voicesFor(all, s.languageCode);
      });
  }

  Future<void> _saveVoice(VoiceSettings v) async {
    setState(() => _voice = v);
    await s.voiceSettings.save(v);
  }

  String _voiceLabel(SpeechVoice v) {
    final i = _voices.indexOf(v);
    final natural = v.name.toLowerCase().contains('network')
        ? ' · natural'
        : '';
    return 'Voice ${i + 1} · ${v.locale}$natural';
  }

  Future<void> _pickVoice() async {
    final chosen = await showDialog<SpeechVoice?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Voice'),
        children: [
          SimpleDialogOption(
            key: const Key('voice-auto'),
            onPressed: () =>
                Navigator.pop(ctx, const SpeechVoice(name: '', locale: '')),
            child: const Text('Automatic (the best one for your language)'),
          ),
          for (final v in _voices)
            SimpleDialogOption(
              key: Key('voice-${v.name}'),
              onPressed: () => Navigator.pop(ctx, v),
              child: Text(_voiceLabel(v)),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    await _saveVoice(
      chosen.name.isEmpty
          ? _voice.copyWith(clearVoice: true)
          : _voice.copyWith(voiceName: chosen.name, locale: chosen.locale),
    );
    await s.speaker.speak('Hi, this is how I sound.');
  }

  Future<void> _permissions() async {
    final usage = await s.native.hasUsageAccess().catchError((_) => false);
    final notifications = await s.native.notificationsAllowed().catchError(
      (_) => false,
    );
    final alarms = await s.native.canScheduleExactAlarms().catchError(
      (_) => false,
    );
    final overlay = await s.native.canDrawOverlay().catchError((_) => false);
    if (mounted)
      setState(() {
        _usage = usage;
        _notifications = notifications;
        _alarms = alarms;
        _overlay = overlay;
      });
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  static TimeOfDay _parse(String v) => TimeOfDay(
    hour: int.parse(v.substring(0, 2)),
    minute: int.parse(v.substring(3)),
  );

  Future<void> _pick(bool wake) async {
    final current = wake ? _wake : _sleep;
    final picked = await showTimePicker(
      context: context,
      initialTime: current != null
          ? _parse(current)
          : TimeOfDay(hour: wake ? 7 : 23, minute: wake ? 0 : 0),
    );
    if (picked == null) return;
    setState(() => wake ? _wake = _fmt(picked) : _sleep = _fmt(picked));
  }

  Future<void> _pickApps() async {
    List<String> installed;
    try {
      installed = await s.native.installedApps();
    } catch (_) {
      installed = [];
    }
    final all = {...installed, ..._apps}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (!mounted) return;
    final chosen = {..._apps};
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Apps that pull you away'),
          content: SizedBox(
            width: double.maxFinite,
            child: all.isEmpty
                ? const Text('No apps found.')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final a in all)
                        CheckboxListTile(
                          key: Key('app-$a'),
                          value: chosen.contains(a),
                          title: Text(a),
                          onChanged: (v) => setInner(() {
                            if (v == true && chosen.length < 8) chosen.add(a);
                            if (v != true) chosen.remove(a);
                          }),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('apps-done'),
              onPressed: () => Navigator.pop(ctx, chosen.toList()),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (result != null) setState(() => _apps = result);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await s.api.profile(
        set: Profile(
          wake: _wake,
          sleep: _sleep,
          apps: _apps,
          focus: _focus.text.trim().isEmpty ? null : _focus.text.trim(),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted)
        setState(
          () => _error = 'Could not save. Check your connection and try again.',
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Your day', style: theme.textTheme.titleMedium),
          ListTile(
            key: const Key('wake'),
            leading: const Icon(Icons.wb_sunny_outlined),
            title: const Text('I wake up at'),
            trailing: Text(_wake ?? 'Set'),
            onTap: () => _pick(true),
          ),
          ListTile(
            key: const Key('sleep'),
            leading: const Icon(Icons.bedtime_outlined),
            title: const Text('I go to sleep at'),
            trailing: Text(_sleep ?? 'Set'),
            onTap: () => _pick(false),
          ),
          ListTile(
            key: const Key('apps'),
            leading: const Icon(Icons.apps_outlined),
            title: const Text('Apps that pull me away'),
            subtitle: Text(
              _apps.isEmpty ? 'None chosen (up to 8)' : _apps.join(', '),
            ),
            onTap: _pickApps,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              key: const Key('focus'),
              controller: _focus,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'What I am working towards (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                key: const Key('error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              key: const Key('save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
          const Divider(),
          Text('Voice', style: theme.textTheme.titleMedium),
          SwitchListTile(
            key: const Key('voice-enabled'),
            title: const Text('Read answers aloud after I talk'),
            subtitle: const Text('A short version, never the links'),
            value: _voice.enabled,
            onChanged: (v) => _saveVoice(_voice.copyWith(enabled: v)),
          ),
          ListTile(
            key: const Key('voice'),
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('Voice'),
            subtitle: Text(
              _voice.voiceName == null
                  ? 'Automatic'
                  : _voiceLabel(
                      SpeechVoice(
                        name: _voice.voiceName!,
                        locale: _voice.locale ?? '',
                      ),
                    ),
            ),
            onTap: _voices.isEmpty ? null : _pickVoice,
          ),
          ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('Speed'),
            subtitle: Slider(
              key: const Key('voice-rate'),
              min: 0.3,
              max: 0.8,
              divisions: 10,
              value: _voice.rate.clamp(0.3, 0.8),
              onChanged: (v) =>
                  setState(() => _voice = _voice.copyWith(rate: v)),
              onChangeEnd: (v) => _saveVoice(_voice.copyWith(rate: v)),
            ),
          ),
          TextButton.icon(
            key: const Key('voice-sample'),
            onPressed: () => s.speaker.speak(
              'Hi, this is how I sound. Tell me about your day.',
            ),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Hear a sample'),
          ),
          const Divider(),
          Text('Permissions', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          _Perm(
            key: const Key('perm-usage'),
            icon: Icons.insights_outlined,
            title: 'Usage access',
            why: 'Lets me see your real screen time',
            granted: _usage,
            onTap: () async {
              await s.native.openUsageAccessSettings();
            },
          ),
          _Perm(
            key: const Key('perm-notifications'),
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            why: 'For nudges and reminders',
            granted: _notifications,
            onTap: () async {
              await s.native.requestNotifications();
              _permissions();
            },
          ),
          _Perm(
            key: const Key('perm-alarms'),
            icon: Icons.alarm_outlined,
            title: 'Alarms and reminders',
            why: 'So reminders arrive on time',
            granted: _alarms,
            onTap: () async {
              await s.native.openExactAlarmSettings();
            },
          ),
          _Perm(
            key: const Key('perm-overlay'),
            icon: Icons.layers_outlined,
            title: 'Show over other apps',
            why:
                'Lets a nudge appear on top of the app you are in (optional: otherwise you get a notification)',
            granted: _overlay,
            onTap: () async {
              await s.native.openOverlaySettings();
            },
          ),
          TextButton(onPressed: _permissions, child: const Text('Check again')),
        ],
      ),
    );
  }
}

class _Perm extends StatelessWidget {
  const _Perm({
    super.key,
    required this.icon,
    required this.title,
    required this.why,
    required this.granted,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String why;
  final bool granted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(why),
    trailing: granted
        ? const Icon(Icons.check_circle, color: Colors.green)
        : OutlinedButton(onPressed: onTap, child: const Text('Allow')),
  );
}
