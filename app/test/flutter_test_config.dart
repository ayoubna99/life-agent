import 'dart:async';

import 'package:life_agent/ui/motion.dart';

/// Runs before every test file: the endless background motion is off, so `pumpAndSettle` can settle.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Ambient.enabled = false;
  await testMain();
}
