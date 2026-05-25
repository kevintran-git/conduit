import 'dart:async';
import 'dart:convert';

import '../../core/utils/reasoning_parser.dart';

/// Rewrites an OpenAI-compatible SSE byte stream so any raw reasoning tags
/// (e.g. `<think>...</think>`) inside `choices[0].delta.content` are routed
/// into `choices[0].delta.reasoning_content` instead.
///
/// Why: gateway models (Gemini, Anthropic via proxies, etc.) emit raw think
/// tags inline. Without this, the streaming-helper appends them verbatim to
/// the assistant message, which means TTS reads them out loud and they get
/// folded back into chat context. Open WebUI's middleware normalizes the same
/// way server-side — we mirror it client-side because we bypass that server.
///
/// Downstream effects after this transform:
///  - UI: `applyStreamingReasoningDelta` already wraps reasoning into a
///    `<details type="reasoning">` block, which renders as the collapsible
///    "thinking" widget.
///  - Context: `ToolCallsParser.sanitizeForApi` already strips those blocks
///    before history is sent back to any model.
///
/// Handles tags that straddle chunk boundaries by buffering the trailing
/// candidate bytes until the next chunk arrives.
Stream<List<int>> splitReasoningTagsInSseStream(Stream<List<int>> source) {
  final controller = StreamController<List<int>>();
  final splitter = _ReasoningTagSplitter(defaultReasoningTagPairs);
  final frameBuffer = StringBuffer();

  late StreamSubscription<String> sub;
  sub = source
      .cast<List<int>>()
      .transform(utf8.decoder)
      .listen(
        (chunk) {
          frameBuffer.write(chunk.replaceAll('\r\n', '\n'));
          for (final frame in _takeCompleteFrames(frameBuffer)) {
            final rewritten = _rewriteFrame(frame, splitter);
            if (rewritten != null) {
              controller.add(utf8.encode('$rewritten\n\n'));
            }
          }
        },
        onError: controller.addError,
        onDone: () {
          final trailing = frameBuffer.toString();
          frameBuffer.clear();
          if (trailing.trim().isNotEmpty) {
            final rewritten = _rewriteFrame(trailing, splitter);
            if (rewritten != null) {
              controller.add(utf8.encode(rewritten));
            }
          }
          // Drain anything the splitter is still holding (e.g. an unterminated
          // tag at end-of-stream).
          final remainder = splitter.flush();
          if (remainder.content.isNotEmpty || remainder.reasoning.isNotEmpty) {
            controller.add(
              utf8.encode('${_buildDeltaFrame(remainder)}\n\n'),
            );
          }
          controller.close();
        },
        cancelOnError: false,
      );
  controller.onCancel = sub.cancel;
  return controller.stream;
}

/// SSE frame splitter: pulls completed `\n\n`-terminated frames out of
/// [buffer], leaves any incomplete trailing frame behind.
List<String> _takeCompleteFrames(StringBuffer buffer) {
  final text = buffer.toString();
  final parts = text.split('\n\n');
  buffer
    ..clear()
    ..write(parts.removeLast());
  return parts.where((p) => p.trim().isNotEmpty).toList(growable: false);
}

/// Rewrites a single SSE frame. Returns the new frame text (without the
/// trailing `\n\n`), or null if the frame should be dropped.
///
/// Preserves comment lines, event/id lines, and all other JSON fields
/// untouched — we only mutate `choices[0].delta.content` and
/// `delta.reasoning_content`.
String? _rewriteFrame(String frame, _ReasoningTagSplitter splitter) {
  final lines = frame.split('\n');
  final dataLines = <String>[];
  final nonDataLines = <String>[];
  for (final line in lines) {
    if (line.startsWith('data:')) {
      dataLines.add(line.substring(5).trimLeft());
    } else {
      nonDataLines.add(line);
    }
  }
  if (dataLines.isEmpty) {
    return nonDataLines.join('\n');
  }
  final dataPayload = dataLines.join('\n');
  if (dataPayload == '[DONE]') {
    // Flush any unterminated reasoning before the terminator so the UI
    // doesn't drop the tail of an in-flight think block.
    final remainder = splitter.flush();
    final framesOut = <String>[];
    if (remainder.content.isNotEmpty || remainder.reasoning.isNotEmpty) {
      framesOut.add(_buildDeltaFrame(remainder));
    }
    framesOut.add('${nonDataLines.join('\n')}\ndata: [DONE]'.trimLeft());
    return framesOut.join('\n\n');
  }

  Map<String, dynamic>? parsed;
  try {
    final decoded = jsonDecode(dataPayload);
    if (decoded is Map<String, dynamic>) parsed = decoded;
  } catch (_) {
    // Non-JSON payload — pass through unchanged.
    return frame;
  }
  if (parsed == null) return frame;

  final choices = parsed['choices'];
  if (choices is! List || choices.isEmpty) return frame;
  final first = choices.first;
  if (first is! Map) return frame;
  final delta = first['delta'];
  if (delta is! Map) return frame;

  final rawContent = delta['content'];
  // Only string deltas are splittable. (Some servers send `null` for tool-only
  // chunks; pass those through.)
  if (rawContent is! String || rawContent.isEmpty) return frame;

  final split = splitter.consume(rawContent);
  // Merge any pre-existing reasoning_content with what we split out.
  final existingReasoning = delta['reasoning_content'];
  final mergedReasoning = StringBuffer();
  if (existingReasoning is String && existingReasoning.isNotEmpty) {
    mergedReasoning.write(existingReasoning);
  }
  mergedReasoning.write(split.reasoning);

  delta['content'] = split.content;
  if (mergedReasoning.isNotEmpty) {
    delta['reasoning_content'] = mergedReasoning.toString();
  }

  // Re-emit with the original frame's non-data prefix lines (event:, id:, …).
  final rebuiltData = jsonEncode(parsed);
  if (nonDataLines.isEmpty) return 'data: $rebuiltData';
  return '${nonDataLines.join('\n')}\ndata: $rebuiltData';
}

/// Build a fresh delta-only SSE frame body from a split result.
String _buildDeltaFrame(_SplitChunk chunk) {
  final delta = <String, dynamic>{};
  if (chunk.content.isNotEmpty) delta['content'] = chunk.content;
  if (chunk.reasoning.isNotEmpty) delta['reasoning_content'] = chunk.reasoning;
  final body = jsonEncode({
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': null},
    ],
  });
  return 'data: $body';
}

/// Output of one splitter call.
class _SplitChunk {
  const _SplitChunk(this.content, this.reasoning);
  final String content;
  final String reasoning;
}

/// Streaming state machine that splits a text stream on a fixed set of
/// reasoning tag pairs. Tags that straddle chunk boundaries are buffered until
/// they resolve.
class _ReasoningTagSplitter {
  _ReasoningTagSplitter(this._tagPairs) {
    _maxOpenLen = _tagPairs
        .map((p) => p.$1.length)
        .fold<int>(0, (a, b) => a > b ? a : b);
  }

  final List<(String, String)> _tagPairs;
  late final int _maxOpenLen;

  String _buffer = '';
  bool _inReasoning = false;
  String _activeEndTag = '';

  _SplitChunk consume(String chunk) {
    _buffer += chunk;
    final content = StringBuffer();
    final reasoning = StringBuffer();

    while (true) {
      if (_inReasoning) {
        final endIdx = _buffer.indexOf(_activeEndTag);
        if (endIdx >= 0) {
          if (endIdx > 0) reasoning.write(_buffer.substring(0, endIdx));
          _buffer = _buffer.substring(endIdx + _activeEndTag.length);
          _inReasoning = false;
          _activeEndTag = '';
          continue;
        }
        // No close yet — hold back the tail that *could* still be the start
        // of the close tag, flush the rest as reasoning.
        final safe = _safeFlushLength(_buffer, _activeEndTag);
        if (safe > 0) {
          reasoning.write(_buffer.substring(0, safe));
          _buffer = _buffer.substring(safe);
        }
        break;
      } else {
        // Find the earliest opening tag.
        int bestStart = -1;
        int bestOpenLen = 0;
        String? bestEnd;
        for (final (open, close) in _tagPairs) {
          final idx = _buffer.indexOf(open);
          if (idx < 0) continue;
          if (bestStart < 0 || idx < bestStart) {
            bestStart = idx;
            bestOpenLen = open.length;
            bestEnd = close;
          }
        }
        if (bestStart >= 0) {
          if (bestStart > 0) content.write(_buffer.substring(0, bestStart));
          _buffer = _buffer.substring(bestStart + bestOpenLen);
          _inReasoning = true;
          _activeEndTag = bestEnd!;
          continue;
        }
        // No open tag in buffer — hold back the tail bytes that could still be
        // a prefix of any opening tag.
        final safe = _safeFlushLengthForOpens(_buffer);
        if (safe > 0) {
          content.write(_buffer.substring(0, safe));
          _buffer = _buffer.substring(safe);
        }
        break;
      }
    }

    return _SplitChunk(content.toString(), reasoning.toString());
  }

  /// Drain remaining buffer at end-of-stream — any unterminated tag is best-
  /// effort treated as reasoning (so we don't dump raw `<think>` into the
  /// visible content).
  _SplitChunk flush() {
    final content = StringBuffer();
    final reasoning = StringBuffer();
    if (_buffer.isNotEmpty) {
      if (_inReasoning) {
        reasoning.write(_buffer);
      } else {
        content.write(_buffer);
      }
      _buffer = '';
    }
    _inReasoning = false;
    _activeEndTag = '';
    return _SplitChunk(content.toString(), reasoning.toString());
  }

  /// Returns how many bytes from the start of [buffer] can be safely flushed
  /// without losing a tag whose first bytes are at the tail.
  int _safeFlushLength(String buffer, String tag) {
    if (buffer.isEmpty) return 0;
    final maxHold = tag.length - 1;
    if (buffer.length <= maxHold) {
      // Whole buffer might be a prefix of the tag — hold it all.
      return tag.startsWith(buffer) ? 0 : buffer.length;
    }
    // Walk back up to maxHold chars: find the longest suffix that is a prefix
    // of the tag, hold that many; flush the rest.
    final start = buffer.length - maxHold;
    for (int i = start; i < buffer.length; i++) {
      final tail = buffer.substring(i);
      if (tag.startsWith(tail)) return i;
    }
    return buffer.length;
  }

  /// Same as [_safeFlushLength] but considering all possible opening tags.
  int _safeFlushLengthForOpens(String buffer) {
    if (buffer.isEmpty) return 0;
    final maxHold = _maxOpenLen - 1;
    if (maxHold <= 0) return buffer.length;
    final start = buffer.length > maxHold ? buffer.length - maxHold : 0;
    for (int i = start; i < buffer.length; i++) {
      final tail = buffer.substring(i);
      for (final (open, _) in _tagPairs) {
        if (open.startsWith(tail)) return i;
      }
    }
    return buffer.length;
  }
}
