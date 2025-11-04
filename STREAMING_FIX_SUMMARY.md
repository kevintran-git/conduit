# LLM Streaming Fix for Unreliable Connections

## Problem Summary

When streaming responses on unreliable connections:
- UI shows blank/waiting while streaming
- Stream gets interrupted (connection drops, network hiccups)
- Backend DOES complete the response
- But frontend never shows it - just stays blank
- Manual reload DOES show the response (because it fetches from server)
- Need automatic retry like the manual reload, without losing streaming

## The Solution (Simplified)

The fix is actually simple: **when the stream fails, do what you do manually - fetch the conversation from the server**.

### Three Key Points Where Streams Fail:

1. **Stream closes without receiving any data** (connection dropped immediately)
2. **Stream errors** (timeouts, network issues)
3. **App backgrounding/recovery** (persistent streaming service callback)

### What We Do at Each Point:

**Automatic "reload"** - fetch the conversation from the server and update the message.

This reuses the existing `api.getConversation()` logic - the same thing that happens when you manually reload.

## The Code Changes

### 1. Recovery Callback (for persistent streaming service)

When the persistent streaming service detects an interrupted stream and tries to recover:

```dart
recoveryCallback: () async {
  // Fetch conversation from server (like a manual reload)
  final conversation = await api.getConversation(chatId);
  
  // Find our message
  final assistant = conversation.messages.firstWhere(
    (m) => m.role == 'assistant' && m.id == assistantMessageId
  );
  
  // Update UI with the content
  if (assistant != null && assistant.content.isNotEmpty) {
    replaceLastMessageContent(assistant.content);
    // Update metadata too (follow-ups, sources, etc.)
  }
  
  finishStreaming();
}
```

### 2. Stream Closes Without Data

When the SSE stream closes without receiving any data:

```dart
if (!hasReceivedData) {
  // Wait 1 second for backend to finish
  await Future.delayed(const Duration(seconds: 1));
  
  // Fetch conversation from server
  final conversation = await api.getConversation(chatId);
  final assistant = conversation.messages.firstWhere(...);
  
  if (assistant != null && assistant.content.isNotEmpty) {
    // Got it! Update UI
    replaceLastMessageContent(assistant.content);
    finishStreaming();
  } else {
    // Not ready yet - persistent service will retry
  }
}
```

### 3. Stream Errors

When a recoverable error occurs (timeout, connection drop):

```dart
onError: (error, stackTrace) async {
  // Try WebSocket reconnection first
  if (isRecoverable && socketService != null) {
    await socketService.ensureConnected();
    return; // Let socket handle it
  }
  
  // Fallback: fetch from server
  await refreshConversationSnapshot(); // Does the same fetch as above
  finishStreaming();
}
```

## How It Works

### Normal Flow (No Issues)
1. Send message → backend starts processing
2. SSE stream delivers chunks in real-time
3. UI updates as chunks arrive
4. Stream completes naturally

### Interrupted Flow (Connection Issues)
1. Send message → backend starts processing  
2. SSE stream starts but then **drops** (blank UI)
3. **NEW**: Wait 1 second, then fetch conversation from server
4. If backend finished → show complete message ✅
5. If backend still working → persistent service retries (exponential backoff)
6. Eventually backend finishes and retry succeeds ✅

### Key Insight

**Backend completion and frontend streaming are decoupled**. The backend can finish while the frontend stream is broken. So we just need to check the server for the completed message!

## Why This Is Simple

- **Reuses existing code**: `api.getConversation()` already exists
- **Mimics manual reload**: Does exactly what you do manually
- **No complex recovery**: Just "check if backend finished"
- **Works with existing infrastructure**: PersistentStreamingService handles retries

## Testing

### To Verify It Works:

1. **Enable airplane mode** mid-stream
   - Wait 2 seconds
   - Disable airplane mode
   - Content should appear within 1-3 seconds

2. **Use network throttling** (Chrome DevTools: Slow 3G)
   - Send a message
   - Watch stream struggle/fail
   - Content should still appear

3. **Background app** during streaming
   - Return to foreground after 10+ seconds
   - Content should be there

### What You Should See in Logs:

```
Stream closed without data - checking if backend completed
Backend had completed - recovered content
```

or

```
Stream interrupted - checking if backend completed
Stream error occurred
```

Followed by the message appearing in the UI.

## Comparison: Before vs After

### Before
- Stream fails → UI stays blank forever
- User has to manually reload
- Frustrating experience

### After  
- Stream fails → Auto-checks server after 1 second
- If backend done → Shows message automatically
- If backend still working → Retries every few seconds (exponential backoff)
- User doesn't have to do anything

## Edge Cases Handled

1. **Backend slow**: Retries with backoff until it completes
2. **Multiple failures**: Up to 3 retry attempts before giving up
3. **Backgrounding**: Saves state, recovers on foreground
4. **Partial content**: Replaces with full content from server
5. **No content yet**: Keeps retrying via persistent service

## Future Improvements

1. **Show retry indicator**: "Reconnecting..." toast to user
2. **Configurable delays**: Make the 1-second delay configurable
3. **Smarter resume**: Resume streaming from last received position (but complex)
4. **Better error messages**: Show specific status to users

## Files Changed

- `lib/core/services/streaming_helper.dart`: Main changes (3 locations)
  - Recovery callback (~50 lines)
  - onDone handler (~50 lines)  
  - onError handler (~5 lines)

**Total changed:** ~100 lines, but mostly simple fetch-and-update logic

## The Simplicity Win

Instead of complex stream resumption or state management:
- **Just fetch the completed message** from the server
- **Reuse existing code** that already works
- **Same as manual reload** but automatic

This is way simpler than trying to:
- Resume streaming mid-chunk
- Merge partial content
- Track streaming positions
- Handle protocol-specific recovery

**The backend has the truth. When in doubt, ask the backend!** 🎯
