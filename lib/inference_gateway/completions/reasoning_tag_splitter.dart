/// Rewrites an OpenAI-compatible SSE byte stream so any raw reasoning tags
/// (e.g. `<think>...</think>`) inside `choices[0].delta.content` are routed
/// into `choices[0].delta.reasoning_content` instead.
///
/// Why: gateway models (Gemini, Anthropic via proxies, etc.) emit raw think
/// tags inline. Without this, the streaming-helper appends them verbatim to
/// the assistant message — TTS reads them aloud and they fold back into chat
/// history on the next turn.
///
/// The implementation now lives in the shared `inference_kit` package (extracted
/// verbatim from this file); this re-export keeps Conduit's import path and
/// behavior unchanged.
library;

export 'package:inference_kit/inference_kit.dart'
    show splitReasoningTagsInSseStream;
