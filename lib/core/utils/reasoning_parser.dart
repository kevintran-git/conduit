/// Reasoning / "thinking" parsing for Conduit.
///
/// The implementation now lives in the shared, backend-agnostic `inference_kit`
/// package so the same reasoning logic is not rebuilt per app. This file is a
/// thin re-export that keeps Conduit's import path (`core/utils/reasoning_parser`)
/// and public API byte-for-byte stable. The engine was extracted verbatim from
/// this file, so behavior is unchanged.
///
/// Handles `<details type="reasoning">` blocks (server-emitted, preferred) and
/// raw tag pairs like `<think>`, `<thinking>`, `<reasoning>`, etc.
/// Reference: openwebui-src/backend/open_webui/utils/middleware.py
library;

export 'package:inference_kit/inference_kit.dart'
    show
        defaultReasoningTagPairs,
        CollapsibleBlockType,
        ReasoningEntry,
        ReasoningSegment,
        ReasoningContent,
        ReasoningParser;
