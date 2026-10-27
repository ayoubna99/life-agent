/// What the agent can do on the phone. The server names the tool and its arguments; the phone does the work and
/// reports back in plain words, so the agent can tell the user what really happened.
abstract class DeviceTools {
  Future<Map<String, Object?>> run(String name, Map<String, Object?> args);

  /// The morning run is about to apply a plan: remember what was already set up today.
  Future<void> beginRun() async {}

  /// The run finished normally: today now mirrors the plan, so tasks, limits and reminders it no longer has are removed.
  Future<void> endRun() async {}
}
