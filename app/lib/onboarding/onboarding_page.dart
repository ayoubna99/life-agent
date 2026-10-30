import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../agent/models.dart';
import '../app_services.dart';
import '../ui/last_night.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'onboarding_store.dart';

/// Shows the welcome slides the first time, then [child] (the home screen) forever after.
class OnboardingGate extends StatefulWidget {
  const OnboardingGate({
    super.key,
    required this.services,
    required this.child,
  });

  final AppServices services;
  final Widget child;

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  bool? _done;

  @override
  void initState() {
    super.initState();
    widget.services.onboarding.done().then((d) {
      if (mounted) setState(() => _done = d);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.slow,
    switchInCurve: Motion.curve,
    transitionBuilder: (child, a) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(begin: 1.04, end: 1.0).animate(a),
        child: child,
      ),
    ),
    child: switch (_done) {
      null => const ColoredBox(key: Key('ob-loading'), color: Brand.cream),
      false => OnboardingFlow(
        key: const Key('onboarding'),
        services: widget.services,
        onDone: () => setState(() => _done = true),
      ),
      true => KeyedSubtree(key: const Key('app'), child: widget.child),
    },
  );
}

/// The five welcome slides: hello, your name, permissions, a reality check of your screen time, and Lify.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.services,
    required this.onDone,
  });

  final AppServices services;
  final VoidCallback onDone;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow>
    with WidgetsBindingObserver {
  static const _count = 5;
  final _pages = PageController();
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  int _page = 0;

  // permissions
  bool _usage = false,
      _notifications = false,
      _alarms = false,
      _overlay = false,
      _calendar = false;

  // reality check
  RealityCheck? _reality;
  bool _realityLoading = false;
  final Set<String> _apps = {};

  // Lify
  String _wake = '07:00';
  PhoneNight? _lastNight;
  String _sleep = '23:00';
  bool _finishing = false;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _name.addListener(() => setState(() {}));
    _checkPermissions();
    _loadLastNight();
  }

  /// When the phone went quiet last night, for "Last night your phone went quiet at 03:12" next to the sleep time.
  Future<void> _loadLastNight() async {
    try {
      final nights = await s.native.phoneNights(nights: 2);
      if (mounted && nights.isNotEmpty)
        setState(() => _lastNight = nights.first);
    } catch (_) {
      // no usage access yet: nothing to say
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pages.dispose();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // back from the phone's settings: see what was turned on
    if (state == AppLifecycleState.resumed) {
      _checkPermissions().then((_) {
        if (_page == 3 && _usage && _reality == null) _loadReality();
        if (_usage && _lastNight == null) _loadLastNight();
      });
    }
  }

  Future<void> _checkPermissions() async {
    final n = s.native;
    final r = await Future.wait([
      n.hasUsageAccess().catchError((_) => false),
      n.notificationsAllowed().catchError((_) => false),
      n.canScheduleExactAlarms().catchError((_) => false),
      n.canDrawOverlay().catchError((_) => false),
      n.hasCalendarAccess().catchError((_) => false),
    ]);
    if (mounted) {
      setState(() {
        _usage = r[0];
        _notifications = r[1];
        _alarms = r[2];
        _overlay = r[3];
        _calendar = r[4];
      });
    }
  }

  Future<void> _loadReality() async {
    if (!_usage) return;
    setState(() => _realityLoading = true);
    RealityCheck reality;
    try {
      reality = RealityCheck.from(
        await s.native.usageSummary(days: 7),
        today: s.today,
      );
    } catch (_) {
      reality = const RealityCheck(minutesPerDay: 0, days: 0, topApps: []);
    }
    if (!mounted) return;
    setState(() {
      _reality = reality;
      _realityLoading = false;
      // the three biggest are the likely culprits; the person can change it
      if (_apps.isEmpty) _apps.addAll(reality.topApps.take(3).map((a) => a.$1));
    });
  }

  String get _firstName => _name.text.trim();

  bool get _canContinue => switch (_page) {
    1 => _firstName.isNotEmpty,
    _ => !_finishing,
  };

  String get _cta => switch (_page) {
    0 => 'Let\'s begin',
    1 => 'Continue',
    2 => _usage ? 'Continue' : 'Skip for now',
    3 =>
      _reality != null && !_reality!.empty
          ? 'I want that time back'
          : 'Continue',
    _ => 'Let\'s go, Lify',
  };

  Future<void> _next() async {
    FocusScope.of(context).unfocus();
    if (_page == _count - 1) return _finish();
    final to = _page + 1;
    setState(() => _page = to);
    await _pages.animateToPage(
      to,
      duration: Motion.slow,
      curve: Curves.easeInOutCubic,
    );
    if (to == 1) _nameFocus.requestFocus();
    if (to == 3 && _reality == null) _loadReality();
  }

  void _back() {
    if (_page == 0) return;
    FocusScope.of(context).unfocus();
    setState(() => _page--);
    _pages.animateToPage(
      _page,
      duration: Motion.slow,
      curve: Curves.easeInOutCubic,
    );
  }

  Future<void> _finish() async {
    setState(() => _finishing = true);
    s.speaker.stop();
    await s.onboarding.saveName(_firstName);
    try {
      await s.api.profile(
        set: Profile(
          name: _firstName,
          wake: _wake,
          sleep: _sleep,
          apps: _apps.take(8).toList(),
        ),
      );
    } catch (_) {
      // offline: the name is on the phone, the rest can be set in Settings later
    }
    try {
      await s.native.configureEvening(
        sleep: _sleep,
      ); // "let's plan tomorrow", one hour before
    } catch (_) {}
    await s.onboarding.finish();
    if (mounted) widget.onDone();
  }

  Future<void> _pickTime(bool wake) async {
    final current = wake ? _wake : _sleep;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.parse(current.substring(0, 2)),
        minute: int.parse(current.substring(3)),
      ),
    );
    if (picked == null) return;
    final v =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() => wake ? _wake = v : _sleep = v);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // keep the slides readable, and on one screen, with very large text settings
    return MediaQuery(
      data: mq.copyWith(textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3)),
      child: Theme(
        // the slides are always the warm daytime look, whatever the phone's theme
        data: lifeTheme(Brightness.light),
        child: Scaffold(
          backgroundColor: Brand.cream,
          resizeToAvoidBottomInset: true,
          body: Stack(
            children: [
              Positioned.fill(child: _Backdrop(page: _page)),
              SafeArea(
                child: Column(
                  children: [
                    _TopBar(page: _page, count: _count, onBack: _back),
                    Expanded(
                      child: PageView(
                        controller: _pages,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          const _WelcomeSlide(),
                          _NameSlide(
                            controller: _name,
                            focus: _nameFocus,
                            onSubmit: _next,
                          ),
                          _PermissionsSlide(
                            usage: _usage,
                            notifications: _notifications,
                            alarms: _alarms,
                            overlay: _overlay,
                            calendar: _calendar,
                            onUsage: s.native.openUsageAccessSettings,
                            onNotifications: () async {
                              await s.native.requestNotifications();
                              _checkPermissions();
                            },
                            onAlarms: s.native.openExactAlarmSettings,
                            onOverlay: s.native.openOverlaySettings,
                            onCalendar: () async {
                              await s.native.requestCalendar();
                              _checkPermissions();
                            },
                          ),
                          _RealitySlide(
                            usage: _usage,
                            loading: _realityLoading,
                            reality: _reality,
                            chosen: _apps,
                            onAllow: s.native.openUsageAccessSettings,
                            onToggle: (a) => setState(
                              () => _apps.contains(a)
                                  ? _apps.remove(a)
                                  : (_apps.length < 8 ? _apps.add(a) : null),
                            ),
                          ),
                          _LifySlide(
                            visible: _page == 4,
                            name: _firstName,
                            wake: _wake,
                            sleep: _sleep,
                            onWake: () => _pickTime(true),
                            onSleep: () => _pickTime(false),
                            speak: s.speaker.speak,
                            lastNight: _lastNight,
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                      child: _PrimaryButton(
                        key: const Key('ob-next'),
                        label: _cta,
                        busy: _finishing,
                        onTap: _canContinue ? _next : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Back arrow and a segmented progress bar that fills as you go.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.page,
    required this.count,
    required this.onBack,
  });

  final int page;
  final int count;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 24, 0),
    child: Row(
      children: [
        AnimatedOpacity(
          opacity: page == 0 ? 0 : 1,
          duration: Motion.medium,
          child: IconButton(
            key: const Key('ob-back'),
            onPressed: page == 0 ? null : onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        const SizedBox(width: 4),
        for (var i = 0; i < count; i++)
          Expanded(
            child: Container(
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: Brand.peach.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(3),
              ),
              alignment: Alignment.centerLeft,
              child: AnimatedFractionallySizedBox(
                duration: Motion.slow,
                curve: Motion.curve,
                widthFactor: i <= page ? 1 : 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: Brand.sunrise,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.medium,
          height: 60,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: enabled ? Brand.sunrise : null,
            color: enabled ? null : Brand.peach.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(30),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: Brand.coral.withValues(alpha: 0.35),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: AnimatedSwitcher(
            duration: Motion.medium,
            transitionBuilder: (c, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.4),
                  end: Offset.zero,
                ).animate(a),
                child: c,
              ),
            ),
            child: busy
                ? const SizedBox(
                    key: ValueKey('busy'),
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Brand.ink,
                    ),
                  )
                : Row(
                    key: ValueKey(label),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: Brand.sans,
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                            color: Brand.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        color: Brand.ink,
                        size: 20,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A soft warm glow that drifts to a new spot on each slide, with embers floating up.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.page});

  final int page;

  static const _spots = [
    Alignment(0, -0.35),
    Alignment(0.9, -0.9),
    Alignment(-0.9, -0.6),
    Alignment(0.8, 0.1),
    Alignment(0, -0.45),
  ];

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      AnimatedAlign(
        alignment: _spots[page],
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeInOutCubic,
        child: FractionallySizedBox(
          widthFactor: 1.4,
          heightFactor: 0.7,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  Brand.peach.withValues(alpha: 0.7),
                  Brand.peach.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
      ),
      const _Embers(),
    ],
  );
}

class _Embers extends StatefulWidget {
  const _Embers();

  @override
  State<_Embers> createState() => _EmbersState();
}

class _EmbersState extends State<_Embers> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Ambient.on(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(painter: _EmberPainter(_c.value)),
      ),
    ),
  );
}

class _EmberPainter extends CustomPainter {
  _EmberPainter(this.t);

  final double t;
  static final _seeds = List.generate(14, (i) {
    final r = math.Random(i * 7 + 3);
    return (
      r.nextDouble(),
      r.nextDouble(),
      2 + r.nextDouble() * 4,
      0.5 + r.nextDouble(),
    );
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final (x, phase, radius, speed) in _seeds) {
      final p = (t * speed + phase) % 1;
      final y = size.height * (1.05 - p * 1.1);
      final dx = math.sin((p + x) * math.pi * 2) * 14;
      final fade = math.sin(p * math.pi);
      canvas.drawCircle(
        Offset(size.width * x + dx, y),
        radius,
        Paint()..color = Brand.coral.withValues(alpha: 0.22 * fade),
      );
    }
  }

  @override
  bool shouldRepaint(_EmberPainter old) => old.t != t;
}

/// Slide titles: a small coral kicker over a big soft serif line.
class _Heading extends StatelessWidget {
  const _Heading({
    super.key,
    required this.kicker,
    required this.title,
    this.body,
  });

  final String kicker;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: cascade([
        Text(
          kicker.toUpperCase(),
          style: t.labelMedium?.copyWith(
            color: Brand.ember,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 10),
        Text(title, style: t.headlineLarge),
        if (body != null) ...[
          const SizedBox(height: 12),
          Text(body!, style: t.bodyLarge?.copyWith(color: t.bodySmall?.color)),
        ],
      ], start: const Duration(milliseconds: 150)),
    );
  }
}

// 1. Hello ----------------------------------------------------------------------------------------------------------

class _WelcomeSlide extends StatefulWidget {
  const _WelcomeSlide();

  @override
  State<_WelcomeSlide> createState() => _WelcomeSlideState();
}

class _WelcomeSlideState extends State<_WelcomeSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final rise = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.7, curve: Curves.easeOutBack),
    );
    final words = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.35, 1, curve: Motion.curve),
    );
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SunMark(
                  size: 168,
                  rise: rise.value.clamp(0, 1.05),
                  glow: rise.value.clamp(0, 1),
                ),
                const SizedBox(height: 8),
                Opacity(
                  opacity: words.value,
                  child: Transform.translate(
                    offset: Offset(0, 20 * (1 - words.value)),
                    child: Column(
                      children: [
                        Text(
                          'Life',
                          key: const Key('ob-logo'),
                          style: t.displayLarge?.copyWith(fontSize: 64),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Ready to get your life back?',
                          textAlign: TextAlign.center,
                          style: t.headlineSmall?.copyWith(color: Brand.ember),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Plan tomorrow in a few minutes tonight.\nWake up to a phone that works for you.',
                          textAlign: TextAlign.center,
                          style: t.bodyLarge?.copyWith(
                            color: t.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 2. Name -----------------------------------------------------------------------------------------------------------

class _NameSlide extends StatelessWidget {
  const _NameSlide({
    required this.controller,
    required this.focus,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = controller.text.trim();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Heading(
            kicker: 'Nice to meet you',
            title: 'What should I call you?',
            body: 'Your first name is fine.',
          ),
          const SizedBox(height: 32),
          Reveal(
            delay: const Duration(milliseconds: 350),
            child: TextField(
              key: const Key('ob-name'),
              controller: controller,
              focusNode: focus,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              style: t.headlineMedium,
              decoration: const InputDecoration(
                hintText: 'First name',
                counterText: '',
              ),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) onSubmit();
              },
            ),
          ),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: Motion.medium,
            transitionBuilder: (c, a) => FadeTransition(
              opacity: a,
              child: ScaleTransition(
                scale: Tween(begin: 0.9, end: 1.0).animate(a),
                child: c,
              ),
            ),
            child: name.isEmpty
                ? const SizedBox(key: ValueKey('none'), height: 32)
                : Row(
                    key: const ValueKey('hello'),
                    children: [
                      const Text('👋', style: TextStyle(fontSize: 24)),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Hi $name. Good to have you here.',
                          style: t.titleMedium?.copyWith(color: Brand.ember),
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

// 3. Permissions ----------------------------------------------------------------------------------------------------

class _PermissionsSlide extends StatelessWidget {
  const _PermissionsSlide({
    required this.usage,
    required this.notifications,
    required this.alarms,
    required this.overlay,
    required this.calendar,
    required this.onUsage,
    required this.onNotifications,
    required this.onAlarms,
    required this.onOverlay,
    required this.onCalendar,
  });

  final bool usage, notifications, alarms, overlay, calendar;
  final VoidCallback onUsage, onNotifications, onAlarms, onOverlay, onCalendar;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final granted = [
      usage,
      notifications,
      alarms,
      overlay,
      calendar,
    ].where((g) => g).length;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Heading(
            kicker: 'So I can actually help',
            title: 'A few permissions',
            body:
                'Each one opens the phone\'s settings. Turn it on, then come back here.',
          ),
          const SizedBox(height: 24),
          ...cascade([
            _PermCard(
              key: const Key('ob-perm-usage'),
              icon: Icons.insights_rounded,
              title: 'Usage access',
              why: 'Your real screen time, so plans fit your actual day',
              granted: usage,
              onTap: onUsage,
              essential: true,
            ),
            _PermCard(
              key: const Key('ob-perm-notifications'),
              icon: Icons.notifications_rounded,
              title: 'Notifications',
              why: 'Your reminders and my nudges',
              granted: notifications,
              onTap: onNotifications,
            ),
            _PermCard(
              key: const Key('ob-perm-alarms'),
              icon: Icons.alarm_rounded,
              title: 'Alarms and reminders',
              why: 'So reminders arrive right on time',
              granted: alarms,
              onTap: onAlarms,
            ),
            _PermCard(
              key: const Key('ob-perm-overlay'),
              icon: Icons.layers_rounded,
              title: 'Show over other apps',
              why: 'A gentle card on top of the app you are scrolling',
              granted: overlay,
              onTap: onOverlay,
            ),
            _PermCard(
              key: const Key('ob-perm-calendar'),
              icon: Icons.event_rounded,
              title: 'Calendar',
              why:
                  'I plan around your events, and guard your lectures and meetings',
              granted: calendar,
              onTap: onCalendar,
            ),
          ], start: const Duration(milliseconds: 300)),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 16,
                color: t.bodySmall?.color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Lify only sees minutes per app per day, never what you do inside them.  $granted of 5 on.',
                  style: t.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PermCard extends StatelessWidget {
  const _PermCard({
    super.key,
    required this.icon,
    required this.title,
    required this.why,
    required this.granted,
    required this.onTap,
    this.essential = false,
  });

  final IconData icon;
  final String title;
  final String why;
  final bool granted;
  final VoidCallback onTap;
  final bool essential;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: granted ? null : onTap,
        child: AnimatedContainer(
          duration: Motion.medium,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: granted ? const Color(0xFFFFEDE4) : Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: granted
                  ? Brand.coral.withValues(alpha: 0.5)
                  : const Color(0xFFEADBCF),
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: Motion.medium,
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: granted ? Brand.sunrise : null,
                  color: granted ? null : Brand.sand,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: Brand.ink, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(title, style: t.titleMedium)),
                        if (essential) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Brand.peach,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Key',
                              style: t.labelSmall?.copyWith(color: Brand.ink),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(why, style: t.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: Motion.medium,
                transitionBuilder: (c, a) => ScaleTransition(
                  scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
                  child: c,
                ),
                child: granted
                    ? const Icon(
                        Icons.check_circle_rounded,
                        key: ValueKey('on'),
                        color: Brand.coral,
                        size: 30,
                      )
                    : Container(
                        key: const ValueKey('off'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Brand.ink,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Allow',
                          style: t.labelLarge?.copyWith(color: Brand.cream),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 4. Reality check --------------------------------------------------------------------------------------------------

class _RealitySlide extends StatelessWidget {
  const _RealitySlide({
    required this.usage,
    required this.loading,
    required this.reality,
    required this.chosen,
    required this.onAllow,
    required this.onToggle,
  });

  final bool usage;
  final bool loading;
  final RealityCheck? reality;
  final Set<String> chosen;
  final VoidCallback onAllow;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = reality;
    Widget body;
    if (!usage) {
      body = Column(
        key: const ValueKey('no-access'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Heading(
            kicker: 'Reality check',
            title: 'How much of your day does your phone take?',
            body:
                'Turn on Usage access and I will show you your real numbers. No guessing.',
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            key: const Key('ob-reality-allow'),
            onPressed: onAllow,
            icon: const Icon(Icons.insights_rounded),
            label: const Text('Allow usage access'),
          ),
        ],
      );
    } else if (loading || r == null) {
      body = const SizedBox(
        key: ValueKey('loading'),
        height: 280,
        child: Center(child: CircularProgressIndicator(color: Brand.coral)),
      );
    } else if (r.empty) {
      body = const _Heading(
        key: ValueKey('empty'),
        kicker: 'Reality check',
        title: 'Not much history yet',
        body:
            'Your phone has not recorded enough screen time. I will learn your day as we go.',
      );
    } else {
      final top = r.topApps.isEmpty ? 1 : r.topApps.first.$2;
      body = Column(
        key: const ValueKey('numbers'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REALITY CHECK',
            style: t.labelMedium?.copyWith(
              color: Brand.ember,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Reveal(
            child: Text('Every day, your phone takes', style: t.titleLarge),
          ),
          const SizedBox(height: 4),
          Reveal(
            delay: const Duration(milliseconds: 150),
            child: ShaderMask(
              shaderCallback: (b) => Brand.sunrise.createShader(b),
              child: CountUp(
                key: const Key('ob-total'),
                value: r.minutesPerDay.toDouble(),
                format: (v) => hoursAndMinutes(v.round()),
                style: t.displayLarge?.copyWith(
                  color: Colors.white,
                  fontSize: 68,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Reveal(
            delay: const Duration(milliseconds: 900),
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'That is '),
                  TextSpan(
                    text: '${r.daysPerYear.round()} full days a year',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Brand.ember,
                    ),
                  ),
                  TextSpan(
                    text:
                        ', about ${(r.shareOfWakingDay * 100).round()}% of your waking hours.',
                  ),
                ],
              ),
              style: t.bodyLarge,
            ),
          ),
          const SizedBox(height: 16),
          Reveal(
            delay: const Duration(milliseconds: 1000),
            child: _WakingBar(share: r.shareOfWakingDay),
          ),
          const SizedBox(height: 28),
          Reveal(
            delay: const Duration(milliseconds: 1200),
            child: Text(
              'Which ones pull you away? Tap to choose.',
              style: t.titleMedium,
            ),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < r.topApps.length; i++)
            Reveal(
              delay: Duration(milliseconds: 1300 + 90 * i),
              child: _AppRow(
                name: r.topApps[i].$1,
                minutes: r.topApps[i].$2,
                share: r.topApps[i].$2 / top,
                chosen: chosen.contains(r.topApps[i].$1),
                onTap: () => onToggle(r.topApps[i].$1),
              ),
            ),
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
      child: AnimatedSwitcher(duration: Motion.medium, child: body),
    );
  }
}

/// The waking day as a bar, with the phone's share filling in.
class _WakingBar extends StatelessWidget {
  const _WakingBar({required this.share});

  final double share;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 16,
            width: double.infinity,
            child: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Brand.sand)),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: share),
                  duration: const Duration(milliseconds: 1400),
                  curve: Curves.easeOutQuart,
                  builder: (_, v, _) => FractionallySizedBox(
                    widthFactor: v,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(gradient: Brand.sunrise),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('Phone', style: t.labelSmall?.copyWith(color: Brand.ember)),
            const Spacer(),
            Text('16 waking hours', style: t.labelSmall),
          ],
        ),
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.name,
    required this.minutes,
    required this.share,
    required this.chosen,
    required this.onTap,
  });

  final String name;
  final int minutes;
  final double share;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        key: Key('ob-app-$name'),
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.medium,
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: chosen ? Brand.coral : const Color(0xFFEADBCF),
              width: chosen ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: t.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${hoursAndMinutes(minutes)}/day',
                          style: t.labelMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: share),
                        duration: const Duration(milliseconds: 1100),
                        curve: Curves.easeOutQuart,
                        builder: (_, v, _) => LinearProgressIndicator(
                          value: v,
                          minHeight: 6,
                          backgroundColor: Brand.sand,
                          color: chosen ? Brand.coral : Brand.peach,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              AnimatedSwitcher(
                duration: Motion.fast,
                transitionBuilder: (c, a) =>
                    ScaleTransition(scale: a, child: c),
                child: Icon(
                  chosen
                      ? Icons.check_circle_rounded
                      : Icons.add_circle_outline_rounded,
                  key: ValueKey(chosen),
                  color: chosen ? Brand.coral : const Color(0xFFBFAFA3),
                  size: 26,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 5. Lify -----------------------------------------------------------------------------------------------------------

class _LifySlide extends StatefulWidget {
  const _LifySlide({
    required this.visible,
    required this.name,
    required this.wake,
    required this.sleep,
    required this.onWake,
    required this.onSleep,
    required this.speak,
    this.lastNight,
  });

  final bool visible;
  final String name;
  final String wake;
  final String sleep;
  final VoidCallback onWake;
  final VoidCallback onSleep;
  final Future<void> Function(String) speak;
  final PhoneNight? lastNight;

  @override
  State<_LifySlide> createState() => _LifySlideState();
}

class _LifySlideState extends State<_LifySlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _type = AnimationController(vsync: this);
  bool _started = false;

  String get _hello =>
      'Hi ${widget.name.isEmpty ? 'there' : widget.name}, I\'m Lify.';
  static const _intro =
      'I\'m your friend for getting your life back. Each evening we plan tomorrow together, in a few minutes. '
      'Each morning I set it up on your phone: your tasks, your limits, your reminders.';

  @override
  void initState() {
    super.initState();
    // the page view builds this slide only when it comes into view
    if (widget.visible) _start();
  }

  @override
  void didUpdateWidget(_LifySlide old) {
    super.didUpdateWidget(old);
    if (widget.visible && !_started) _start();
  }

  void _start() {
    _started = true;
    final text = '$_hello $_intro';
    _type.duration = Duration(milliseconds: 26 * text.length);
    _type.forward(from: 0);
    widget.speak(
      'Hi ${widget.name.isEmpty ? 'there' : widget.name}, I\'m Lify, your friend for getting your life back.',
    );
  }

  @override
  void dispose() {
    _type.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final full = '$_hello $_intro';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
      child: AnimatedBuilder(
        animation: _type,
        builder: (context, _) {
          final shown = (full.length * _type.value).round();
          final talking = _type.isAnimating;
          final hello = full.substring(0, math.min(shown, _hello.length));
          final rest = shown > _hello.length
              ? full.substring(_hello.length + 1, shown)
              : '';
          return Column(
            children: [
              LifyOrb(key: const Key('ob-lify'), size: 190, talking: talking),
              const SizedBox(height: 8),
              // the full text is laid out invisibly underneath, so nothing jumps while it types
              Stack(
                children: [
                  Opacity(
                    opacity: 0,
                    child: _LifyWords(hello: _hello, rest: _intro, t: t),
                  ),
                  _LifyWords(
                    hello: hello,
                    rest: rest,
                    t: t,
                    key: const Key('ob-lify-words'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              AnimatedOpacity(
                opacity: _type.value > 0.9 || !_started ? 1 : 0,
                duration: Motion.slow,
                child: Column(
                  children: [
                    Text(
                      'When does your day start and end?',
                      style: t.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _TimeChip(
                            key: const Key('ob-wake'),
                            icon: Icons.wb_sunny_rounded,
                            label: 'I wake up',
                            value: widget.wake,
                            onTap: widget.onWake,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _TimeChip(
                            key: const Key('ob-sleep'),
                            icon: Icons.bedtime_rounded,
                            label: 'I sleep',
                            value: widget.sleep,
                            onTap: widget.onSleep,
                          ),
                        ),
                      ],
                    ),
                    if (widget.lastNight != null) ...[
                      const SizedBox(height: 12),
                      LastNightNote(
                        night: widget.lastNight!,
                        sleep: widget.sleep,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LifyWords extends StatelessWidget {
  const _LifyWords({
    super.key,
    required this.hello,
    required this.rest,
    required this.t,
  });

  final String hello;
  final String rest;
  final TextTheme t;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(hello, textAlign: TextAlign.center, style: t.headlineLarge),
      const SizedBox(height: 12),
      Text(
        rest,
        textAlign: TextAlign.center,
        style: t.bodyLarge?.copyWith(color: t.bodySmall?.color),
      ),
    ],
  );
}

class _TimeChip extends StatelessWidget {
  const _TimeChip({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFEADBCF)),
        ),
        child: Row(
          children: [
            Icon(icon, color: Brand.coral, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: t.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(value, style: t.titleLarge),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
