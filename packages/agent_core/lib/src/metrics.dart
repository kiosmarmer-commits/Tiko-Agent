/// Simple in-process metrics (AGD-07 observability).
class Metrics {
  int tasksTotal = 0;
  int tasksSuccess = 0;
  int tasksFailed = 0;
  int toolCalls = 0;
  int toolErrors = 0;
  int tokensPrompt = 0;
  int tokensCompletion = 0;
  final List<int> latenciesMs = [];

  void recordTask({required bool success, int? latencyMs}) {
    tasksTotal++;
    if (success) {
      tasksSuccess++;
    } else {
      tasksFailed++;
    }
    if (latencyMs != null) {
      latenciesMs.add(latencyMs);
      if (latenciesMs.length > 500) latenciesMs.removeAt(0);
    }
  }

  void recordTool({required bool error}) {
    toolCalls++;
    if (error) toolErrors++;
  }

  void recordTokens({int prompt = 0, int completion = 0}) {
    tokensPrompt += prompt;
    tokensCompletion += completion;
  }

  double get successRate => tasksTotal == 0 ? 0 : tasksSuccess / tasksTotal;

  double get avgLatencyMs {
    if (latenciesMs.isEmpty) return 0;
    return latenciesMs.reduce((a, b) => a + b) / latenciesMs.length;
  }

  Map<String, Object?> snapshot() => {
    'tasks_total': tasksTotal,
    'tasks_success': tasksSuccess,
    'tasks_failed': tasksFailed,
    'success_rate': double.parse(successRate.toStringAsFixed(3)),
    'tool_calls': toolCalls,
    'tool_errors': toolErrors,
    'tokens_prompt': tokensPrompt,
    'tokens_completion': tokensCompletion,
    'avg_latency_ms': avgLatencyMs.round(),
  };
}
