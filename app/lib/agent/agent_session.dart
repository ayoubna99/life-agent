import 'dart:convert';

import '../device/device_tools.dart';
import 'agent_api.dart';
import 'models.dart';

/// What came back from one message to the agent, after every device tool it asked for has been run.
class AgentReply {
  const AgentReply({
    required this.text,
    this.spoken,
    required this.planSaved,
    required this.artifacts,
    required this.toolsRun,
    this.strategyUpdate,
  });

  final String text;
  final String? spoken;
  final bool planSaved;
  final List<Artifact> artifacts;
  final List<ToolRun> toolsRun;
  final StrategyUpdate? strategyUpdate;
}

class ToolRun {
  const ToolRun(this.call, this.result);

  final ToolCall call;
  final Map<String, Object?> result;

  bool get ok => result['ok'] == true;
}

/// One conversation with the agent in one mode. The server keeps the history; we send only the new message,
/// or the results of the device tools it asked for.
class AgentSession {
  AgentSession({
    required this.api,
    required this.tools,
    required this.mode,
    required this.today,
    required this.date,
    this.locale = 'en',
    this.report,
    this.conversationId,
    this.onToolStart,
  });

  static const maxToolRounds = 6;

  final AgentApi api;
  final DeviceTools tools;
  final String mode; // planning | execute | review
  final String today;
  final String date;
  final String locale;
  final Map<String, List<String>>? report;
  String? conversationId;
  bool _began = false;

  /// Lets the screen say "Setting a 30 minute limit for Instagram..." while the tools run.
  final void Function(ToolCall call)? onToolStart;

  Future<AgentReply> send(String text, {List<String> attachments = const []}) {
    return _run({
      'type': 'user',
      'text': text,
      if (attachments.isNotEmpty) 'attachments': attachments,
    });
  }

  Future<AgentReply> _run(Map<String, Object?> firstInput) async {
    var input = firstInput;
    var planSaved = false;
    StrategyUpdate? strategyUpdate;
    final artifacts = <Artifact>[];
    final run = <ToolRun>[];
    if (mode == 'execute' && !_began) {
      _began = true;
      await tools.beginRun();
    }
    for (var round = 0; round <= maxToolRounds; round++) {
      final answer = await api.chat(
        mode: mode,
        today: today,
        date: date,
        conversationId: conversationId,
        locale: locale,
        report: report,
        input: input,
      );
      conversationId = answer.conversationId;
      planSaved = planSaved || answer.planSaved;
      artifacts.addAll(answer.artifacts);
      strategyUpdate = answer.strategyUpdate ?? strategyUpdate;
      if (!answer.wantsTools) {
        if (mode == 'execute') await tools.endRun();
        return AgentReply(
          text: answer.text ?? '',
          spoken: answer.spoken,
          planSaved: planSaved,
          artifacts: artifacts,
          toolsRun: run,
          strategyUpdate: strategyUpdate,
        );
      }
      final results = <Map<String, Object?>>[];
      for (final call in answer.calls) {
        onToolStart?.call(call);
        Map<String, Object?> result;
        try {
          result = await tools.run(call.name, call.args);
        } catch (e) {
          result = {
            'ok': false,
            'error': 'The phone could not do this (${e.runtimeType}).',
          };
        }
        run.add(ToolRun(call, result));
        results.add({'tool_call_id': call.id, 'content': jsonEncode(result)});
      }
      input = {'type': 'tool_results', 'results': results};
    }
    throw AgentException('too_many_tool_rounds');
  }
}
