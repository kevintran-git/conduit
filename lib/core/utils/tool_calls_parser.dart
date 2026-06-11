/// Tool-call (`<details type="tool_calls" ...>`) parsing for Conduit.
///
/// The parsing engine now lives in the shared, backend-agnostic `inference_kit`
/// package (extracted verbatim from this file). This file keeps Conduit's
/// import path and public API stable:
///   * [ToolCallEntry], [ToolCallsContent], [ToolCallsSegment] are re-exported
///     from the kit (identical classes).
///   * [ToolCallsParser] is a thin Conduit facade that delegates all parsing to
///     the kit. Only [ToolCallsParser.sanitizeForApi] is specialized: the kit is
///     markdown-preprocessor-agnostic, so Conduit injects
///     [ConduitMarkdownPreprocessor.sanitize] to preserve its exact behavior.
library;

import 'package:inference_kit/inference_kit.dart' as ik;

import '../../shared/widgets/markdown/markdown_preprocessor.dart';

export 'package:inference_kit/inference_kit.dart'
    show ToolCallEntry, ToolCallsContent, ToolCallsSegment;

/// Conduit-flavored facade over `inference_kit`'s tool-call parser.
class ToolCallsParser {
  /// Split [content] into ordered text / tool-call segments for rendering.
  static List<ik.ToolCallsSegment>? segments(String content) =>
      ik.ToolCallsParser.segments(content);

  /// Parse all tool-call blocks out of [content], returning the cleaned main
  /// content alongside the structured calls.
  static ik.ToolCallsContent? parse(String content) =>
      ik.ToolCallsParser.parse(content);

  /// Human-readable one-line summary of completed tool calls in [content].
  static String summarize(String content) =>
      ik.ToolCallsParser.summarize(content);

  /// Strip Conduit/OWUI rendering artifacts so [content] is safe to send back
  /// to an OpenAI-compatible API. Runs Conduit's markdown preprocessor first
  /// (the kit is preprocessor-agnostic), then the shared sanitization.
  static String sanitizeForApi(String content) =>
      ik.ToolCallsParser.sanitizeForApi(
        content,
        preSanitize: ConduitMarkdownPreprocessor.sanitize,
      );
}
