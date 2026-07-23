import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/voice_call/domain/call_step.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initial state is idle with no error', () {
    check(CallSessionState.initial.step).equals(CallStep.idle);
    check(CallSessionState.initial.errorMessage).isNull();
  });

  test('copyWith only overrides the fields passed', () {
    const state = CallSessionState(
      step: CallStep.listening,
      partialTranscript: 'hello',
    );
    final next = state.copyWith(step: CallStep.thinking);

    check(next.step).equals(CallStep.thinking);
    check(next.partialTranscript).equals('hello');
  });

  test('clearError wins over a simultaneously passed errorMessage', () {
    const state = CallSessionState(step: CallStep.error, errorMessage: 'boom');
    final next = state.copyWith(
      clearError: true,
      errorMessage: 'ignored because clearError is set',
    );

    check(next.errorMessage).isNull();
  });

  test('errorMessage persists across copyWith calls that do not touch it', () {
    const state = CallSessionState(step: CallStep.error, errorMessage: 'boom');
    final next = state.copyWith(step: CallStep.error);

    check(next.errorMessage).equals('boom');
  });

  test(
    'activeToolNames defaults to empty and survives unrelated copyWith calls',
    () {
      check(CallSessionState.initial.activeToolNames).isEmpty();

      const state = CallSessionState(activeToolNames: ['a', 'b']);
      final next = state.copyWith(step: CallStep.listening);

      check(next.activeToolNames).deepEquals(['a', 'b']);
    },
  );
}
