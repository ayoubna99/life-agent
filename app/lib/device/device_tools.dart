/// What the agent can do on the phone. The server names the tool and its arguments; the phone does the work and
/// reports back in plain words, so the agent can tell the user what really happened.
abstract class DeviceTools {
  Future<Map<String, Object?>> run(String name, Map<String, Object?> args);
}
