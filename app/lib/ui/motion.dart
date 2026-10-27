import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Whether the endless background motion (Lify breathing and blinking, the glow behind the sun) runs.
/// Tests switch it off so `pumpAndSettle` can settle; "remove animations" on the phone switches it off too.
class Ambient {
  static bool enabled = true;

  static bool on(BuildContext context) =>
      enabled && !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);
}

/// Fades and slides its child in once, after [delay]. Used to make every screen arrive in a soft cascade.
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 24),
    this.duration = Motion.slow,
  });

  final Widget child;
  final Duration delay;
  final Offset offset;
  final Duration duration;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  // the delay is part of the animation (no timers), so a screen that closes early leaves nothing behind
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.delay + widget.duration,
  )..forward();
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(
      widget.delay.inMicroseconds /
          (widget.delay + widget.duration).inMicroseconds,
      1,
      curve: Motion.curve,
    ),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: widget.offset * (1 - _t.value),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// [Reveal]s a column of children one after the other.
List<Widget> cascade(
  List<Widget> children, {
  Duration start = Duration.zero,
  Duration step = const Duration(milliseconds: 70),
}) => [
  for (var i = 0; i < children.length; i++)
    Reveal(delay: start + step * i, child: children[i]),
];

/// Shrinks a little under the finger and springs back: every big tappable surface uses it.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap != null && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => _set(true),
    onTapUp: (_) => _set(false),
    onTapCancel: () => _set(false),
    onTap: widget.onTap,
    child: AnimatedScale(
      scale: _down ? widget.scale : 1,
      duration: Motion.fast,
      curve: Motion.curve,
      child: widget.child,
    ),
  );
}

/// A number that counts up to [value] the first time it is shown (and glides when it changes).
class CountUp extends StatelessWidget {
  const CountUp({
    super.key,
    required this.value,
    required this.format,
    this.style,
    this.duration = const Duration(milliseconds: 1400),
  });

  final double value;
  final String Function(double) format;
  final TextStyle? style;
  final Duration duration;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: value),
    duration: duration,
    curve: Curves.easeOutQuart,
    builder: (_, v, _) => Text(format(v), style: style),
  );
}

/// The Life mark: a coral sun over a horizon. [rise] 0..1 lifts the sun out of the line.
class SunMark extends StatelessWidget {
  const SunMark({super.key, this.size = 96, this.rise = 1, this.glow = 0});

  final double size;
  final double rise;
  final double glow;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _SunMarkPainter(rise, glow)),
  );
}

class _SunMarkPainter extends CustomPainter {
  _SunMarkPainter(this.rise, this.glow);

  final double rise;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 108;
    final cx = size.width / 2;
    final cy = size.height * 0.62;
    final r = 22 * u;
    final sunCy = cy + r * (1 - rise);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, size.width, cy));
    if (glow > 0) {
      canvas.drawCircle(
        Offset(cx, sunCy),
        r * 2.2,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  Brand.coral.withValues(alpha: 0.4 * glow),
                  Brand.coral.withValues(alpha: 0),
                ],
              ).createShader(
                Rect.fromCircle(center: Offset(cx, sunCy), radius: r * 2.2),
              ),
      );
    }
    canvas.drawCircle(
      Offset(cx, sunCy),
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFF9466), Brand.coral],
        ).createShader(Rect.fromCircle(center: Offset(cx, sunCy), radius: r)),
    );
    canvas.restore();
    canvas.drawLine(
      Offset(cx - 32 * u, cy),
      Offset(cx + 32 * u, cy),
      Paint()
        ..color = Color.lerp(Brand.peach, Brand.coral, rise)!
        ..strokeWidth = 9 * u
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SunMarkPainter old) =>
      old.rise != rise || old.glow != glow;
}

/// Lify: a little sun with a face. It breathes, blinks now and then, and its mouth moves while it [talking].
class LifyOrb extends StatefulWidget {
  const LifyOrb({
    super.key,
    this.size = 120,
    this.talking = false,
    this.mood = 1,
  });

  final double size;
  final bool talking;

  /// 0 = calm (flat smile), 1 = happy (wide smile).
  final double mood;

  @override
  State<LifyOrb> createState() => _LifyOrbState();
}

class _LifyOrbState extends State<LifyOrb> with SingleTickerProviderStateMixin {
  // one slow 4 s loop drives breathing, the blink (near the end of each loop) and the talking mouth
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );
  bool _looping = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final on = Ambient.on(context);
    if (on && !_looping) {
      _c.repeat();
      _looping = true;
    } else if (!on && _looping) {
      _c.stop();
      _looping = false;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: widget.mood),
        duration: Motion.medium,
        builder: (context, mood, _) => CustomPaint(
          size: Size.square(widget.size),
          painter: _LifyPainter(
            t: _c.value,
            talking: widget.talking && _looping,
            mood: mood,
          ),
        ),
      ),
    ),
  );
}

class _LifyPainter extends CustomPainter {
  _LifyPainter({required this.t, required this.talking, required this.mood});

  final double t;
  final bool talking;
  final double mood;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final breathe = math.sin(t * 2 * math.pi);
    final r = size.width * 0.32 * (1 + 0.025 * breathe);

    // soft halo rings that pulse out
    for (var i = 0; i < 2; i++) {
      final p = (t + i * 0.5) % 1;
      canvas.drawCircle(
        c,
        r * (1.15 + 0.45 * p),
        Paint()..color = Brand.coral.withValues(alpha: 0.18 * (1 - p)),
      );
    }
    canvas.drawCircle(
      c,
      r * 1.5,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Brand.peach.withValues(alpha: 0.55),
            Brand.peach.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r * 1.5)),
    );

    // the body: a warm sun, lit from the top left
    final body = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.45),
          radius: 1.1,
          colors: [Color(0xFFFFB08A), Brand.coral, Brand.ember],
          stops: [0, 0.55, 1],
        ).createShader(body),
    );
    // a small shine
    canvas.drawOval(
      Rect.fromCenter(
        center: c + Offset(-r * 0.38, -r * 0.5),
        width: r * 0.42,
        height: r * 0.22,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.35),
    );

    // eyes: blink for a moment near the end of each loop
    final blinkPhase = (t - 0.9) / 0.06;
    final open = blinkPhase > 0 && blinkPhase < 1
        ? (1 - math.sin(blinkPhase * math.pi)).clamp(0.1, 1.0)
        : 1.0;
    final eye = Paint()..color = Brand.ink;
    for (final dx in [-0.34, 0.34]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: c + Offset(r * dx, -r * 0.08),
          width: r * 0.16,
          height: r * 0.22 * open,
        ),
        eye,
      );
    }
    // cheeks
    for (final dx in [-0.56, 0.56]) {
      canvas.drawCircle(
        c + Offset(r * dx, r * 0.18),
        r * 0.11,
        Paint()..color = const Color(0xFFFF5A3C).withValues(alpha: 0.45),
      );
    }

    // mouth: a smile, opening and closing while talking
    final mouthY = c.dy + r * 0.28;
    final w = r * (0.32 + 0.12 * mood);
    if (talking) {
      final o = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 9)).abs();
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(c.dx, mouthY + r * 0.04),
          width: w * 0.9,
          height: r * 0.22 * o,
        ),
        eye,
      );
    } else {
      final path = Path()
        ..moveTo(c.dx - w / 2, mouthY)
        ..quadraticBezierTo(
          c.dx,
          mouthY + r * (0.08 + 0.18 * mood),
          c.dx + w / 2,
          mouthY,
        );
      canvas.drawPath(
        path,
        Paint()
          ..color = Brand.ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.075
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_LifyPainter old) =>
      old.t != t || old.talking != talking || old.mood != mood;
}

/// A ring that fills to [value] (0..1), used for the day's progress.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.value,
    this.size = 64,
    this.stroke = 7,
    this.child,
    this.track,
    this.color = Brand.coral,
  });

  final double value;
  final double size;
  final double stroke;
  final Widget? child;
  final Color? track;
  final Color color;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value.clamp(0, 1)),
    duration: const Duration(milliseconds: 900),
    curve: Curves.easeOutCubic,
    builder: (context, v, _) => SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(
          v,
          stroke,
          track ?? Theme.of(context).colorScheme.outlineVariant,
          color,
        ),
        child: Center(child: child),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v, this.stroke, this.track, this.color);

  final double v;
  final double stroke;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * math.pi, false, p..color = track);
    if (v > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * v,
        false,
        p..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.v != v || old.track != track;
}
