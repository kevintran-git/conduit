# Chat Streaming Mode Feature

## Overview

Added a new **Chat Streaming Mode** setting that lets you control how LLM responses are streamed to the app. This helps debug SSE vs WebSocket streaming issues.

**NEW**: Visual indicator shows the active streaming mode in real-time with color-coded badges during streaming!

## Visual Debugging

### Real-Time Mode Indicator
When a message is streaming, you'll see a small badge next to the stop button:
- **SSE+WS** (Blue) - Hybrid mode using both transports
- **WS** (Green) - WebSocket only mode 
- **SSE** (Orange) - SSE only mode

This makes it instantly clear which transport is active without checking logs!

### Reduced Logging Verbosity
- No more per-chunk logs flooding the console
- Summary logs every 20 chunks: `Streaming progress: 40 chunks, 1250 chars`
- Final summary when complete: `Streaming completed: 127 chunks, 3894 total chars`
- Clear startup log: `🔌 Streaming mode: ws | SSE: ❌ | WebSocket: ✅`

## What Changed

### New Setting: Chat Streaming Mode

Located in: **Settings → App Customization → Realtime section**

Three modes:
1. **Hybrid (SSE + WebSocket)** - Default
   - Uses HTTP Server-Sent Events for content chunks
   - Uses WebSocket for metadata (tools, sources, follow-ups)
   - Best reliability, matches web client behavior

2. **WebSocket Only**
   - All content via WebSocket events
   - Good for testing when SSE is failing
   - Your current issue: SSE closes immediately, but WebSocket works perfectly

3. **SSE Only** 
   - All content via HTTP SSE stream
   - Good for debugging SSE-specific issues
   - May miss some metadata that only comes via WebSocket

## Testing Your Issue

Based on your logs, you should test:

### Step 1: Verify Current Behavior
1. Open Settings → App Customization
2. Scroll to "Realtime" section
3. Current mode should show "Hybrid (SSE + WebSocket)"
4. Send a test message and check logs

### Step 2: Test WebSocket-Only Mode
1. Tap "Chat streaming" setting
2. Select "WebSocket only"
3. Send a test message
4. **Expected**: Streaming should work perfectly (since your WebSocket is fine)
5. Check logs - you should see:
   ```
   Chat streaming mode: ws (SSE: false, WebSocket: true)
   Skipping SSE subscription (WebSocket-only mode)
   ```

### Step 3: Test SSE-Only Mode (Debug)
1. Tap "Chat streaming" setting
2. Select "SSE only"
3. Send a test message
4. **Expected**: Streaming will fail (confirms SSE is the problem)
5. Check logs - you should see:
   ```
   Chat streaming mode: sse (SSE: true, WebSocket: false)
   Skipping WebSocket subscriptions (SSE-only mode)
   Source stream onDone fired, hasReceivedData=false
   ```

## Files Modified

### Core Settings
- `lib/core/persistence/persistence_keys.dart` - Added `chatStreamingMode` key
- `lib/core/services/settings_service.dart` - Added getter/setter for chat streaming mode
- `lib/l10n/app_en.arb` - Added localization strings

### UI
- `lib/features/profile/views/app_customization_page.dart` - Added streaming mode picker
- `lib/features/chat/widgets/modern_chat_input.dart` - Added visual mode indicator badge

### Streaming Logic
- `lib/core/services/streaming_helper.dart` - 
  - Added `chatStreamingMode` parameter
  - Conditionally subscribes to SSE stream based on mode
  - Conditionally registers WebSocket handlers based on mode
  - Reduced verbose logging (summary every 20 chunks instead of every chunk)
  - Added clear visual logs with emojis and status indicators
- `lib/features/chat/providers/chat_providers.dart` - Passes setting to streaming helper

## Why This Helps

Your logs show:
```
308: Auth interceptor for /api/chat/completions  
310: Source stream onDone fired, hasReceivedData=false ← SSE closes instantly!
338-427: [WebSocket successfully delivers all content]
```

**The Problem**: HTTP SSE closes immediately without data, but WebSocket works fine.

**The Fix**: Use "WebSocket Only" mode to bypass the failing SSE stream entirely.

## Why SSE Might Be Failing

Possible causes (in order of likelihood):

1. **Server Preference** - Your OpenWebUI instance might prefer WebSocket and close SSE
2. **iOS Network Stack** - iOS handles HTTP streaming differently than desktop
3. **HTTP Keep-Alive** - Connection settings might not be staying open
4. **Dio Configuration** - Flutter's HTTP client might have different defaults

## Next Steps

### To Fix SSE (Optional)
If you want SSE to work too, add logging to `lib/core/services/api_service.dart`:

```dart
// Around line 2615
final resp = await _dio.post(
  '/api/chat/completions',
  data: data,
  options: Options(
    responseType: ResponseType.stream,
    receiveTimeout: const Duration(minutes: 10),
    headers: {
      'Accept': 'text/event-stream',
      'Connection': 'keep-alive',
      'Cache-Control': 'no-cache',
    },
  ),
  onSendProgress: (sent, total) {
    print('SSE Request sent: $sent/$total');  // ← Add this
  },
);

// After getting response
print('SSE Response status: ${resp.statusCode}');  // ← Add this
print('SSE Response headers: ${resp.headers}');    // ← Add this
```

### Recommended Action
Just use **"WebSocket Only"** mode - your WebSocket works perfectly, so there's no need to debug SSE unless you specifically need it.

## Build Instructions

To apply these changes:

```bash
cd /Users/kevintran/Development/GitHub/conduit

# Regenerate localization files (if you get errors)
flutter gen-l10n

# Regenerate code (settings service)
dart run build_runner build --delete-conflicting-outputs

# Run the app
flutter run
```

## Testing Checklist

- [ ] Open Settings → App Customization
- [ ] See "Chat streaming" option under "Realtime"
- [ ] Tap to see 3 modes: Hybrid, WebSocket only, SSE only
- [ ] Select "WebSocket only"
- [ ] Send a chat message
- [ ] **See "WS" badge (green) next to stop button** ✨
- [ ] Verify streaming works perfectly
- [ ] Check logs show: `🔌 Streaming mode: ws | SSE: ❌ | WebSocket: ✅`
- [ ] See progress logs every 20 chunks, not every single chunk
- [ ] See final summary: `Streaming completed: X chunks, Y total chars`

