import 'package:checks/checks.dart';
import 'package:conduit/core/services/background_streaming_handler.dart';
import 'package:conduit/inference_gateway/voice_call/application/call_background_lease.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackgroundStreamingHandler implements BackgroundStreamingHandler {
  final List<bool> externalOwnerCalls = <bool>[];
  List<String>? startedStreamIds;
  bool? startedRequiresMicrophone;
  BackgroundStreamKind? startedKind;
  List<String>? stoppedStreamIds;

  @override
  Future<void> setExternalAudioSessionOwner(bool isExternal) async {
    externalOwnerCalls.add(isExternal);
  }

  @override
  Future<void> startBackgroundExecution(
    List<String> streamIds, {
    bool requiresMicrophone = false,
    BackgroundStreamKind kind = BackgroundStreamKind.chat,
    bool isReply = false,
  }) async {
    startedStreamIds = streamIds;
    startedRequiresMicrophone = requiresMicrophone;
    startedKind = kind;
  }

  @override
  Future<void> stopBackgroundExecution(List<String> streamIds) async {
    stoppedStreamIds = streamIds;
  }

  @override
  Future<bool> keepAlive() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'marks audio session as app-owned and requests microphone voice lease',
    () async {
      final handler = _FakeBackgroundStreamingHandler();
      final lease = CallBackgroundLease(leaseId: 'call-1', handler: handler);

      await lease.acquire();

      check(handler.externalOwnerCalls).deepEquals(<bool>[false]);
      check(handler.startedStreamIds).isNotNull().deepEquals(<String>['call-1']);
      check(handler.startedRequiresMicrophone).equals(true);
      check(handler.startedKind).equals(BackgroundStreamKind.voice);

      await lease.release();

      check(handler.stoppedStreamIds).isNotNull().deepEquals(<String>['call-1']);
      check(handler.externalOwnerCalls).deepEquals(<bool>[false, false]);
    },
  );
}
