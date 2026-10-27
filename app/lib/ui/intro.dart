import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The opening moment: a cream horizon draws in and a coral sun rises over it, then the app fades in.
/// Tap to skip. With [enabled] false (tests, or "remove animations" on the phone) the app shows at once.
class IntroGate extends StatefulWidget {
  const IntroGate({
    super.key,
    required this.child,
    this.enabled = true,
    this.duration = const Duration(milliseconds: 1500),
  });

  final Widget child;
  final bool enabled;
  final Duration duration;

  @override
  State<IntroGate> createState() => _IntroGateState();
}

class _IntroGateState extends State<IntroGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      _done = true;
      return;
    }
    _c.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_done || reduce) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        GestureDetector(
          key: const Key('intro'),
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _done = true),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              // the whole screen fades out in the last 25% of the animation
              final fade = _c.value < 0.75 ? 1.0 : 1 - (_c.value - 0.75) / 0.25;
              return Opacity(
                opacity: fade.clamp(0.0, 1.0),
                child: CustomPaint(painter: _SunrisePainter(_c.value)),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SunrisePainter extends CustomPainter {
  _SunrisePainter(this.t);

  final double t; // 0..1

  double _ease(double x) => 1 - math.pow(1 - x.clamp(0.0, 1.0), 3).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Brand.cream);
    final cx = size.width / 2;
    final cy = size.height * 0.52;
    final unit = math.min(size.width, size.height) / 108 * 1.5;

    // 0.00 - 0.35: the horizon draws from the middle outwards
    final line = _ease(t / 0.35);
    final half = 29 * unit * line;
    final strokeW = 9 * unit;
    final linePaint = Paint()
      ..color = Brand.peach
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx - half, cy), Offset(cx + half, cy), linePaint);

    // 0.25 - 0.80: the sun rises out of the line and a soft glow comes with it
    final rise = _ease((t - 0.25) / 0.55);
    if (rise > 0) {
      final r = 20 * unit;
      final sunCy = cy + r * (1 - rise);
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(0, 0, size.width, cy),
      ); // only the part above the horizon shows
      canvas.drawCircle(
        Offset(cx, sunCy),
        r * 1.9,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  Brand.coral.withValues(alpha: 0.35 * rise),
                  Brand.coral.withValues(alpha: 0),
                ],
              ).createShader(
                Rect.fromCircle(center: Offset(cx, sunCy), radius: r * 1.9),
              ),
      );
      canvas.drawCircle(Offset(cx, sunCy), r, Paint()..color = Brand.coral);
      canvas.restore();
      // the horizon takes the coral of the sun once it is up
      canvas.drawLine(
        Offset(cx - half, cy),
        Offset(cx + half, cy),
        Paint()
          ..color = Color.lerp(Brand.peach, Brand.coral, rise)!
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_SunrisePainter old) => old.t != t;
}
