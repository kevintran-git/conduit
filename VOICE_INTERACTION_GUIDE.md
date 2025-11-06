# Hybrid Voice Button - Interaction Guide

## Overview

The Hybrid Voice Button combines **Voice Activity Detection (VAD)**, **Push-to-Talk (PTT)**, and **dynamic pause** functionality into a single, sophisticated button interface.

---

## 🎯 Interaction Model

### **Starting a Recording**

#### 1. **Quick Tap** → VAD Mode (Hands-Free)
- **Action:** Tap the microphone button briefly
- **Result:** Recording starts with VAD (automatic silence detection)
- **Visual:** Button turns **green** with pulsing animation
- **Overlay:** Shows "🎤 VAD Active" with countdown timer
- **Haptic:** Single light tick
- **Best For:** Quick questions, back-and-forth conversation

#### 2. **Long Press (400ms+)** → PTT Mode (Walkie-Talkie)
- **Action:** Press and hold the microphone button
- **Result:** Recording starts in Push-to-Talk mode
- **Visual:** Button turns **red** and solid
- **Overlay:** Shows "🔴 PTT - Hold" with timer
- **Haptic:** Strong thunk when threshold reached
- **Best For:** Controlled recording, noisy environments
- **To Stop:** Release the button

---

### **During VAD Recording**

You have three options:

#### Option A: **Do Nothing** → Auto-Stop
- VAD automatically stops after 2-3 seconds of silence
- Hands-free operation
- **Haptic:** Light double-tick when auto-stopped
- Processing begins immediately

#### Option B: **Tap Button** → Submit Immediately
- "I'm done, send it now" - don't wait for VAD timeout
- Great for cutting yourself off mid-sentence
- **Haptic:** Medium impact
- **Visual:** Button briefly scales down

#### Option C: **Press and Hold Button** → Pause VAD
- **Action:** Press and hold for 300ms+ during recording
- **Result:** VAD temporarily disabled
- **Visual:** Button turns **orange/yellow**
- **Overlay:** Shows "⏸️ Paused - Release to resume"
- **Haptic:** Medium double-pulse when pause activates
- **Use Case:** Taking a breath, thinking, saying "um..."
- **While Holding:**
  - No timeout countdown
  - Can pause, think freely
  - VAD won't cut you off
- **To Resume:** Release the button
  - **Haptic:** Light tick
  - Button returns to green pulsing
  - Fresh silence countdown starts

**You can tap to submit OR hold to pause multiple times in the same recording!**

---

### **During PTT Recording**

- **Keep Holding:** Recording continues
- **Release:** Stops recording and submits
- **Cannot Switch:** Once in PTT mode, stays in PTT mode
- Classic walkie-talkie behavior

---

## 📊 State Diagram

```
NOT RECORDING
    |
    ├─[Quick Tap]──────────→ VAD MODE ────┐
    |                                      |
    |   ┌──────────────────────────────────┘
    |   |
    |   ├─[Do Nothing]───────→ Auto-stop after silence
    |   |
    |   ├─[Tap]──────────────→ Manual submit now
    |   |
    |   └─[Hold]─────────────→ PAUSE VAD (while holding)
    |                              |
    |                              └─[Release]──→ Back to VAD MODE
    |
    └─[Long Press]─────────→ PTT MODE ──[Release]──→ Submit
```

---

## 🎨 Visual States

### **Idle (Not Recording)**
- **Color:** Light blue/gray
- **Icon:** Microphone
- **Shadow:** Minimal
- **Animation:** None

### **VAD Active**
- **Color:** Green
- **Icon:** Microphone
- **Shadow:** Green glow
- **Animation:** Pulsing (1.0x → 1.15x scale)
- **Overlay:** Waveform visualization, timer, help text

### **VAD Paused**
- **Color:** Orange/Yellow
- **Icon:** Pause symbol
- **Shadow:** Orange glow
- **Animation:** Solid (no pulse)
- **Overlay:** "VAD paused" status

### **PTT Mode**
- **Color:** Red
- **Icon:** Stop/Record circle
- **Shadow:** Red glow
- **Animation:** Solid (no pulse)
- **Overlay:** "Release to stop" message

### **Disabled**
- **Color:** Muted gray
- **Icon:** Microphone
- **Opacity:** Reduced
- **Tooltip:** "Voice input unavailable"

---

## 🎮 Haptic Feedback Language

| **Event** | **Haptic Pattern** | **Feel** |
|-----------|-------------------|----------|
| Start VAD mode | Single light tick | Gentle tap |
| Start PTT mode | Strong thunk | Solid impact |
| Pause VAD (hold) | Medium double-pulse | Two taps |
| Resume VAD (release) | Light single tick | Quick tap |
| Manual submit (tap) | Medium impact | Firm tap |
| Auto-submit (silence) | Light double-tick | Two gentle taps |

Users learn to "feel" which mode they're in without looking!

---

## 🧪 Test Scenarios

### **Test 1: Basic VAD Mode**
1. Tap mic button once
2. Say "What's the weather today?"
3. Stop speaking
4. Wait 2-3 seconds
5. ✅ Recording should auto-stop and submit

### **Test 2: VAD with Manual Submit**
1. Tap mic button
2. Say "The capital of France is Berl—"
3. Tap button again mid-sentence
4. ✅ Recording should submit immediately

### **Test 3: VAD with Pause for Thinking**
1. Tap mic button
2. Say "I'm thinking about..."
3. Hold button down (button turns orange)
4. Pause for 5 seconds while holding
5. Release button (button turns green again)
6. Continue: "...the relationship between quantum mechanics and philosophy"
7. Wait for auto-stop
8. ✅ Recording should include both parts without cutting off

### **Test 4: PTT Mode (Classic Walkie-Talkie)**
1. Press and hold mic button until it turns red (400ms)
2. Say "This is a PTT message"
3. Release button
4. ✅ Recording should stop immediately on release

### **Test 5: Multiple Pauses in One Recording**
1. Tap mic button (VAD mode starts)
2. Say "First part"
3. Hold button to pause
4. Think for 2 seconds
5. Release to resume
6. Say "Second part"
7. Hold button to pause again
8. Think for 3 seconds
9. Release to resume
10. Say "Third part"
11. Tap to submit
12. ✅ All three parts should be in one transcript

### **Test 6: Accidental Long Press → PTT**
1. Press mic button and keep holding
2. Notice button turns red after 400ms
3. Say message while holding
4. Release
5. ✅ Should behave as PTT (release stops recording)

### **Test 7: Quick Tap-Hold-Release in VAD**
1. Tap mic button (VAD starts, green)
2. Immediately hold button
3. ✅ Should pause VAD (turn orange)
4. Release immediately
5. ✅ Should resume VAD (turn green)

### **Test 8: Edge Case - Hold at Last Second Before Auto-Stop**
1. Start VAD mode
2. Say something
3. Stop speaking (silence timer starts)
4. Just before 2-3 second timeout, hold button
5. ✅ Should cancel auto-stop and pause VAD
6. Release
7. ✅ Should get fresh 2-3 second timeout

---

## 🐛 Known Edge Cases Handled

### **Scenario:** User taps to start VAD but immediately holds
- **Handled:** First tap starts VAD, immediate hold pauses it

### **Scenario:** User holds button for 5+ seconds in VAD pause mode
- **Handled:** Stays in pause mode indefinitely (no forced submission)

### **Scenario:** VAD is about to auto-stop but user holds just in time
- **Handled:** Hold cancels countdown, mode switches to paused

### **Scenario:** User releases during PTT mode
- **Handled:** Stops recording immediately (expected PTT behavior)

### **Scenario:** Network interruption during server STT
- **Handled:** Error shown in overlay, recording state cleaned up

### **Scenario:** Permission denied for microphone
- **Handled:** Snackbar shows error, button stays disabled

---

## 💡 Pro Tips for Users

1. **Quick Questions:** Just tap and speak - VAD handles the rest
2. **Long Responses:** Tap to start, hold to pause during thinking
3. **Noisy Environment:** Use long-press PTT mode for control
4. **Self-Correction:** Tap mid-sentence to submit early
5. **Continuous Thought:** Chain multiple pause-resume cycles in one recording

---

## 🎯 UX Goals Achieved

✅ **Hands-Free Default:** Quick tap = VAD (most common use case)  
✅ **Power User Options:** PTT and pause available when needed  
✅ **Progressive Disclosure:** Casual users discover features naturally  
✅ **No Wrong Moves:** Every interaction has a logical outcome  
✅ **Tactile Feedback:** Haptics provide mode confirmation without looking  
✅ **Visual Clarity:** Distinct colors for each mode (green/orange/red)  
✅ **Forgiving:** Hold-to-pause prevents accidental cutoffs  
✅ **Flexible:** Single recording can include multiple pauses  

---

## 🔧 Configuration

### **Timing Constants** (in code)

```dart
// Initial long press to trigger PTT mode
static const Duration _initialLongPressDuration = Duration(milliseconds: 400);

// Hold during recording to pause VAD
static const Duration _holdDuringRecordingThreshold = Duration(milliseconds: 300);

// VAD silence timeout (configurable per user)
final silenceDuration = settings.voiceSilenceDuration; // Default: 2000ms
```

### **User Settings**
- VAD silence duration: 1-5 seconds (default: 2 seconds)
- STT preference: Auto, Device-only, Server-only
- Haptic feedback: On/Off

---

## 📱 Platform Support

- ✅ **iOS:** Full support with native STT and haptics
- ✅ **Android:** Full support with native STT and haptics
- ❌ **Web/Desktop:** Not currently supported (Platform.isAndroid/isIOS check)

---

## 🚀 Implementation Files

```
lib/features/chat/
├── models/
│   └── voice_recording_state.dart        # State model and mode enum
├── services/
│   └── voice_input_service.dart          # Extended with pause/resume
└── widgets/
    ├── hybrid_voice_button.dart          # The main button widget
    ├── voice_recording_overlay.dart      # Status and waveform display
    └── modern_chat_input.dart            # Integration point
```

---

## 🎉 Success Metrics

A successful implementation will:
- [ ] Handle all 8 test scenarios correctly
- [ ] Provide clear visual feedback for each state
- [ ] Deliver appropriate haptic feedback at each transition
- [ ] Never leave the user confused about current mode
- [ ] Feel natural and intuitive after first use
- [ ] Support both casual and power users
- [ ] Work seamlessly on both iOS and Android

---

*Built with ❤️ for the ultimate voice input experience!*

