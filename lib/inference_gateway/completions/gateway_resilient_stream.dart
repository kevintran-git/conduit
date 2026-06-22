import 'dart:async';
import 'dart:convert';

import '../../core/utils/debug_logger.dart';

typedef GatewayUpstream = ({
  Stream<List<int>> bytes,
  Future<void> Function() abort,
});

typedef GatewayUpstreamOpener =
    Future<GatewayUpstream> Function(List<Map<String, dynamic>> messages);

class GatewayResumeController {
  Future<void> Function()? _activeAbort;
  bool _stopped = false;

  bool get isStopped => _stopped;

  void bind(Future<void> Function() abort) => _activeAbort = abort;

  Future<void> abort() async {
    _stopped = true;
    await _activeAbort?.call();
  }
}

// [fact] inference_kit streamChat retries only pre-first-byte; mid-stream resume must live here.
Stream<List<int>> resilientGatewayStream({
  required List<Map<String, dynamic>> baseMessages,
  required GatewayUpstreamOpener open,
  required GatewayResumeController controller,
  int maxResumes = 2,
}) async* {
  final content = StringBuffer();
  var attempt = 0;
  var messages = baseMessages;

  while (true) {
    if (controller.isStopped) return;

    final GatewayUpstream upstream;
    try {
      upstream = await open(messages);
    } catch (e) {
      if (attempt == 0) rethrow;
      DebugLogger.error(
        'resume-reopen-failed',
        scope: 'gateway/resume',
        error: e,
      );
      return;
    }
    controller.bind(upstream.abort);

    final dedup = attempt == 0 ? null : _SeamDedup(content.toString());
    var sawDone = false;
    Object? streamError;

    try {
      await for (final frame in _reframeSse(upstream.bytes)) {
        if (frame.isDone) {
          final tail = dedup?.flush() ?? '';
          if (tail.isNotEmpty) {
            content.write(tail);
            yield utf8.encode(_contentFrame(tail));
          }
          sawDone = true;
          yield utf8.encode(frame.raw);
          break;
        }
        final delta = frame.contentDelta;
        if (delta == null) {
          yield utf8.encode(frame.raw);
          continue;
        }
        final emit = dedup == null ? delta : dedup.consume(delta);
        if (emit.isEmpty) continue;
        content.write(emit);
        yield utf8.encode(
          dedup == null && emit == delta ? frame.raw : _contentFrame(emit),
        );
      }
    } catch (e) {
      streamError = e;
    }

    if (!sawDone) {
      final tail = dedup?.flush() ?? '';
      if (tail.isNotEmpty) {
        content.write(tail);
        yield utf8.encode(_contentFrame(tail));
      }
    }

    if (sawDone) return;
    if (controller.isStopped) return;

    final canResume = attempt < maxResumes && content.isNotEmpty;
    if (!canResume) {
      if (content.isEmpty && streamError != null) {
        throw streamError;
      }
      DebugLogger.log(
        'resume-exhausted',
        scope: 'gateway/resume',
        data: {'attempt': attempt, 'kept_chars': content.length},
      );
      return;
    }

    attempt++;
    DebugLogger.log(
      'resume',
      scope: 'gateway/resume',
      data: {'attempt': attempt, 'partial_chars': content.length},
    );
    messages = [
      ...baseMessages,
      {'role': 'assistant', 'content': content.toString()},
    ];
  }
}

class _SeamDedup {
  _SeamDedup(this._partial);

  final String _partial;
  final StringBuffer _pending = StringBuffer();
  bool _resolved = false;

  String consume(String chunk) {
    if (_resolved) return chunk;
    _pending.write(chunk);
    if (_pending.length < _partial.length) return '';
    return _resolve();
  }

  String flush() => _resolved ? '' : _resolve();

  String _resolve() {
    _resolved = true;
    final cont = _pending.toString();
    _pending.clear();
    final maxOverlap =
        _partial.length < cont.length ? _partial.length : cont.length;
    for (var len = maxOverlap; len > 0; len--) {
      if (_partial.endsWith(cont.substring(0, len))) {
        return cont.substring(len);
      }
    }
    return cont;
  }
}

typedef _SseFrame = ({String raw, bool isDone, String? contentDelta});

String _contentFrame(String text) =>
    'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': text},
            },
          ],
        })}\n\n';

Stream<_SseFrame> _reframeSse(Stream<List<int>> bytes) async* {
  final buffer = StringBuffer();
  await for (final chunk in bytes) {
    buffer.write(utf8.decode(chunk, allowMalformed: true));
    var text = buffer.toString();
    int sep;
    while ((sep = text.indexOf('\n\n')) != -1) {
      yield _classifyFrame(text.substring(0, sep + 2));
      text = text.substring(sep + 2);
    }
    buffer
      ..clear()
      ..write(text);
  }
  final tail = buffer.toString();
  if (tail.trim().isNotEmpty) yield _classifyFrame(tail);
}

_SseFrame _classifyFrame(String raw) {
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('data:')) continue;
    final payload = t.substring(5).trim();
    if (payload == '[DONE]') return (raw: raw, isDone: true, contentDelta: null);
    if (payload.isEmpty) continue;
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final choices = json['choices'];
      if (choices is List && choices.isNotEmpty) {
        final delta = (choices.first as Map)['delta'];
        if (delta is Map && delta['content'] is String) {
          return (
            raw: raw,
            isDone: false,
            contentDelta: delta['content'] as String,
          );
        }
      }
    } catch (_) {}
  }
  return (raw: raw, isDone: false, contentDelta: null);
}
