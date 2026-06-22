import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/completions/gateway_resilient_stream.dart';
import 'package:flutter_test/flutter_test.dart';

String _contentFrame(String text) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    })}\n\n';

const _doneFrame = 'data: [DONE]\n\n';

Stream<List<int>> _frames(List<String> frames, {bool drop = false}) async* {
  for (final f in frames) {
    yield utf8.encode(f);
  }
  if (drop) throw const SocketDrop();
}

class SocketDrop implements Exception {
  const SocketDrop();
}

Future<String> _visible(Stream<List<int>> bytes) async {
  final raw = utf8.decode(await bytes.expand((c) => c).toList());
  final out = StringBuffer();
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('data:')) continue;
    final payload = t.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') continue;
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final delta = (json['choices'] as List).first['delta'] as Map;
    if (delta['content'] is String) out.write(delta['content']);
  }
  return out.toString();
}

void main() {
  group('resilientGatewayStream', () {
    test('passes a clean stream through and never resumes', () async {
      var opens = 0;
      final stream = resilientGatewayStream(
        baseMessages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        controller: GatewayResumeController(),
        open: (_) async {
          opens++;
          return (
            bytes: _frames([
              _contentFrame('Hello'),
              _contentFrame(' world'),
              _doneFrame,
            ]),
            abort: () async {},
          );
        },
      );

      check(await _visible(stream)).equals('Hello world');
      check(opens).equals(1);
    });

    test(
      'resumes after a mid-stream drop and dedupes a restating seam',
      () async {
        var opens = 0;
        late List<Map<String, dynamic>> secondRequestMessages;
        final stream = resilientGatewayStream(
          baseMessages: const [
            {'role': 'user', 'content': 'count'},
          ],
          controller: GatewayResumeController(),
          open: (msgs) async {
            opens++;
            if (opens == 1) {
              return (
                bytes: _frames([
                  _contentFrame('The answer is '),
                  _contentFrame('forty'),
                ], drop: true),
                abort: () async {},
              );
            }
            secondRequestMessages = msgs;
            return (
              bytes: _frames([
                _contentFrame('answer is forty'),
                _contentFrame('-two.'),
                _doneFrame,
              ]),
              abort: () async {},
            );
          },
        );

        check(await _visible(stream)).equals('The answer is forty-two.');
        check(opens).equals(2);
        check(
          secondRequestMessages.last,
        ).deepEquals({'role': 'assistant', 'content': 'The answer is forty'});
      },
    );

    test(
      'resumes cleanly when the provider prefills (no restatement)',
      () async {
        var opens = 0;
        final stream = resilientGatewayStream(
          baseMessages: const [
            {'role': 'user', 'content': 'count'},
          ],
          controller: GatewayResumeController(),
          open: (_) async {
            opens++;
            if (opens == 1) {
              return (
                bytes: _frames([_contentFrame('Part one. ')], drop: true),
                abort: () async {},
              );
            }
            return (
              bytes: _frames([_contentFrame('Part two.'), _doneFrame]),
              abort: () async {},
            );
          },
        );

        check(await _visible(stream)).equals('Part one. Part two.');
      },
    );

    test('surfaces a drop that produced no content', () async {
      final stream = resilientGatewayStream(
        baseMessages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        controller: GatewayResumeController(),
        open: (_) async =>
            (bytes: _frames(const [], drop: true), abort: () async {}),
      );

      await check(stream.drain<void>()).throws<SocketDrop>();
    });

    test('stops resuming after maxResumes and keeps the partial', () async {
      var opens = 0;
      final stream = resilientGatewayStream(
        baseMessages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        controller: GatewayResumeController(),
        maxResumes: 1,
        open: (_) async {
          opens++;
          return (
            bytes: _frames([_contentFrame('chunk$opens ')], drop: true),
            abort: () async {},
          );
        },
      );

      check(await _visible(stream)).equals('chunk1 chunk2 ');
      check(opens).equals(2);
    });

    test('abort stops further resume', () async {
      final controller = GatewayResumeController();
      var opens = 0;
      final stream = resilientGatewayStream(
        baseMessages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        controller: controller,
        open: (_) async {
          opens++;
          return (
            bytes: () async* {
              yield utf8.encode(_contentFrame('streaming'));
              await controller.abort();
              throw const SocketDrop();
            }(),
            abort: () async {},
          );
        },
      );

      check(await _visible(stream)).equals('streaming');
      check(opens).equals(1);
    });
  });
}
