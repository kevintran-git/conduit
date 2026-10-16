# Building Conduit

## Requirements

| | |
| --- | --- |
| Flutter SDK | Flutter `3.47.0` or newer, Dart `3.13.0` or newer |
| Android | Java 17+, AGP 9.1.0, KGP 2.4.0, Gradle 9.3.1, Android SDK 36. Runs on Android 7.0+ (API 24) |
| iOS | Xcode with an iOS 16.0+ deployment target |
| Backend | An Open WebUI instance, an OpenAI-compatible API, an Ollama endpoint, or a Hermes server |

Apple On-Device requires Xcode 26 and an iOS 26 device with Apple Intelligence.
It uses the local SystemLanguageModel with a 4K context window; image input,
reasoning controls, and tool parameters are rejected.

Apple Private Cloud Compute requires Xcode 27, an iOS 27 device with Apple
Intelligence, and Apple's managed PCC entitlement. PCC is compiled out on older
SDKs, so the iOS build keeps its iOS 16 deployment target. PCC accepts image data
URLs and the Direct parameters `temperature`, `max_tokens`, `top_p`, `top_k`,
`seed`, and OpenAI-style `response_format.json_schema`; tool parameters are
rejected.

## Clone

```bash
git clone --recursive https://github.com/cogwheel0/conduit.git
```

`--recursive` is required. Existing clone: `git submodule update --init --recursive`.

- `third_party/mermaid`: Mermaid renderer packages (`mermaid_core`,
  `mermaid_flutter`), referenced by path from `pubspec.yaml`. Without it,
  `flutter pub get` fails.
- `third_party/katex`: KaTeX assets for math rendering.
- `openwebui-src`: Open WebUI checkout, used only as an API reference. Not built
  or shipped.
- `hermes-src`: Hermes Agent checkout, used only as the reference for the gateway
  RPC and REST contracts (`tui_gateway/`, `gateway/platforms/api_server.py`). Not
  built or shipped.

## Run

```bash
flutter pub get
dart run build_runner build
XCODE_XCCONFIG_FILE="$PWD/ios/Flutter/ArmOnly.xcconfig" flutter run -d ios
# or
flutter run -d android
```

`build_runner` is required. Riverpod providers, Freezed models, JSON
serialization, Drift tables, and Pigeon bindings generate into git-ignored
`*.g.dart` / `*.freezed.dart` files. A fresh clone or worktree has none of them,
so the analyzer reports hundreds of errors until codegen runs. Run codegen before
debugging missing-symbol errors.

`ArmOnly.xcconfig` excludes x86_64 from the app, extensions, and Swift packages,
so the iOS simulator build targets Apple Silicon only. Use an ARM emulator or
device for Android development.

Pigeon is pinned separately because its analyzer constraint does not overlap the
Dart 3.13-compatible Riverpod and Freezed generators. Regenerate platform
bindings with its isolated dependencies:

```bash
dart pub get --directory tool/pigeon_codegen
dart tool/pigeon_codegen/bin/generate.dart
```

`vad` 0.0.8 declares Record 6.x support. The root `pubspec.yaml` pins VAD and
overrides `record` to 7.1.1. Conduit passes VAD a PCM stream owned by
`VoiceInputService`, so VAD never creates its incompatible internal recorder.
Remove the override and the exact VAD pin when
[upstream issue #22](https://github.com/keyur2maru/vad/issues/22) ships Record 7
support. Keep the Conduit-owned stream until upstream also preserves externally
managed iOS audio sessions.

## Verify

```bash
flutter pub get && dart run build_runner build   # required on a fresh clone
flutter analyze
dart run tool/run_test_shards.dart          # combines test files into 8 entrypoints by default (much faster than flutter test); --shards=<n>
flutter test <file>                         # single file
```

`flutter analyze` and the test suite are the local gates. CI (`.github/workflows/ci.yml`) runs the analyzer and the shard runner on pushes to `main` and on pull requests.

Tests use `flutter_test` with `package:checks` for assertions and `mocktail` for
mocks. Lints come from `flutter_lints` plus `riverpod_lint`.

## Release builds

```bash
# Android
flutter build apk --target-platform android-arm,android-arm64 --release
flutter build appbundle --target-platform android-arm,android-arm64 --release

# iOS
XCODE_XCCONFIG_FILE="$PWD/ios/Flutter/ArmOnly.xcconfig" flutter build ios --release
```

`scripts/release.sh` drives the tagged release flow used by the maintainer.

## Localization

Translations live in `lib/l10n/*.arb`, configured by `l10n.yaml`. `app_en.arb`
is the template; every other locale mirrors its keys. Do not hand-edit the
generated localization Dart. Edit the ARB inputs and regenerate.

Every key in `app_en.arb` needs an `@key` entry with a `description`. That
description is the only context a translator gets. CI runs:

```bash
dart run tool/validate_arb_locales.dart
dart run tool/verify_arb_descriptions.dart
```

## Conventions

- Diagnostics go through `DebugLogger` (`packages/conduit_core/lib/utils/debug_logger.dart`)
  with slash-scoped `scope:` values like `auth/proxy` or `streaming/helper`. No
  raw `print` calls.
- Credentials and auth tokens belong in `flutter_secure_storage` via
  `SecureCredentialStorage`. Auth-bearing headers stay scoped to Dio clients
  configured for the selected `ServerConfig.url`.
- The API client is split by endpoint family across
  `packages/conduit_core/lib/services/api_service*.dart`. Verify endpoint names
  against `openwebui-src/` before adding or changing API calls.
- Chat markdown is sanitized in `lib/features/chat/views/chat_page.dart`, but
  Chart.js blocks still render through a WebView in
  `lib/shared/widgets/markdown/markdown_config.dart`. Treat model output as
  untrusted when touching that pipeline.

## Platform permissions

**Android** requests microphone (voice input), camera (image capture), and optional
location (sharing) access. Attachments go through the system photo picker, so no broad storage permission is needed.

**iOS** requests microphone, speech recognition, camera, photo library, and
optional location-when-in-use access.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `flutter pub get` cannot resolve `mermaid_core` | Submodules are missing. Run `git submodule update --init --recursive`. |
| Analyzer reports errors in files you never touched | Generated code is missing. Run `dart run build_runner build`. |
| Codegen fails with output conflicts | `dart run build_runner build --delete-conflicting-outputs` |
| iOS device build fails | `cd ios && pod install`, then confirm signing in Xcode. |
| Android build fails | Check the Java 17 / Gradle toolchain, then `flutter clean`. |
| Streaming stalls against your server | Confirm `ENABLE_WEBSOCKET_SUPPORT="true"` on the Open WebUI deployment. |
