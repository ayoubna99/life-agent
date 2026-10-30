import 'package:flutter/material.dart';

import '../agent/models.dart';
import 'theme.dart';

/// What last night's phone use says next to the chosen sleep time: "Last night your phone went quiet at 03:12. Don't
/// worry, we'll fix this together." Phone use, never a claim about sleep.
String lastNightLine(PhoneNight night, String sleep) {
  final late = nightMinutes(night.down) - nightMinutes(sleep);
  if (late >= 45) {
    return 'Last night your phone went quiet at ${night.down}. Don\'t worry, we\'ll fix this together.';
  }
  if (late <= 0) {
    return 'Last night your phone went quiet at ${night.down}. Right on time, let\'s keep it that way.';
  }
  return 'Last night your phone went quiet at ${night.down}, close to $sleep.';
}

class LastNightNote extends StatelessWidget {
  const LastNightNote({
    super.key,
    required this.night,
    required this.sleep,
    this.dark = false,
  });

  final PhoneNight night;
  final String sleep;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final late = nightMinutes(night.down) - nightMinutes(sleep) >= 45;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      child: Container(
        key: ValueKey('${night.down}-$sleep'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: late ? Brand.dusk : Brand.peach.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Icon(
              Icons.bedtime_rounded,
              size: 20,
              color: late ? Brand.peach : Brand.ink,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                lastNightLine(night, sleep),
                key: const Key('last-night'),
                style: t.bodyMedium?.copyWith(
                  color: late ? Brand.cream : Brand.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
