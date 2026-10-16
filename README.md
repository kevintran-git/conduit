<h1 align="center">Conduit</h1>

<p align="center">
  <img
    src="assets/icons/icon.png"
    alt="Conduit icon"
    width="96"
    height="96"
  />
</p>

<p align="center">
  <strong>A native mobile client for Open WebUI, your own model endpoints, and self-hosted agents.</strong>
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/conduit-open-webui-client/id6749840287">App Store</a> ·
  <a href="https://play.google.com/store/apps/details?id=app.cogwheel.conduit">Google Play</a> ·
  <a href="docs/BUILDING.md">Build from Source</a>
</p>

Conduit is a Flutter app. It works with or without an Open WebUI server.
Chats, notes, and drafts are stored on the device; notes and drafts work offline. Nothing routes through a
backend the maintainer operates.

## Ways to connect

Pick one on first launch and add others later. Skip any sign-in you don't need.

| Option | Backend | Notes |
| --- | --- | --- |
| **Open WebUI** | Self-hosted Open WebUI server | Chats, folders, notes, channels, workspace, tools, web search, image generation |
| **Direct** | OpenAI-compatible, Ollama, OpenRouter | No Open WebUI account required |
| **Apple On-Device** | Apple Intelligence, iOS 26 | Offline, no API key. No image input, reasoning controls, or tool calling |
| **Apple PCC** | Apple Private Cloud Compute, iOS 27 | No API key. Requires Apple's managed PCC entitlement. Optional on-device fallback on PCC network failure. No tool calling |
| **Hermes** | Self-hosted Hermes agent | Live tool activity, approval of sensitive steps, scheduled agents |

Direct connections cover OpenAI-compatible endpoints (Chat Completions or
Responses), LM Studio, Azure-style API versions, native Ollama, and first-party
OpenRouter. An API key is optional for local endpoints. Direct connections
configured in Open WebUI carry over automatically. Keys and custom headers are
kept in platform secure storage.

Hermes exposes only the capabilities the server reports. Server-dependent
features (channels, notes, web search, image generation, toggle filters,
terminal) appear only when the deployment exposes them.

## Getting started

<details open>
<summary><strong>Open WebUI</strong></summary>

1. Launch Conduit and choose Open WebUI.
2. Enter your instance's base URL and any required custom headers.
3. Sign in with username and password, LDAP, JWT, SSO, or proxy auth.
4. Pick a model and start chatting.

</details>

<details>
<summary><strong>Direct connection</strong></summary>

1. Launch Conduit and choose Direct connection.
2. Add an OpenAI-compatible or Ollama profile with its base URL and any API key or custom headers.
3. Test the connection, enable it, and select a discovered or manually entered model.
4. Choose whether new direct chats use Open WebUI history (when signed in) or stay on this device. Existing chats keep their current location.

</details>

<details>
<summary><strong>Apple On-Device and Apple PCC</strong></summary>

1. On an eligible iOS 26 (On-Device) or iOS 27 (PCC) device, launch Conduit and choose the Apple provider.
2. Conduit checks Apple Intelligence and model availability. No API key is required.
3. Apple-only installations keep Direct history on the device unless you enable Open WebUI history.

</details>

<details>
<summary><strong>Hermes Agent</strong></summary>

1. Launch Conduit and choose Hermes Agent.
2. Enter your Hermes server URL and `API_SERVER_KEY`.
3. Optionally set a memory key to scope the agent's long-term memory to you. One is generated on the first chat if you leave it blank.
4. Open the Hermes tab for conversations and scheduled agents.

</details>

## Privacy

- Credentials use platform secure storage: Keychain on iOS, Keystore on Android.
- No third-party analytics or advertising SDKs. Diagnostic logging is local and transient.
- Traffic goes from the device to the configured server or provider only.
- Signing out lets you choose what stays on the device. Clearing everything also clears on-device chats, and fails safely rather than half-deleting.

Full details in [PRIVACY_POLICY.md](PRIVACY_POLICY.md).

## Build from source

See **[docs/BUILDING.md](docs/BUILDING.md)** for requirements, submodules,
codegen, verification, and troubleshooting.

```bash
git clone --recursive https://github.com/cogwheel0/conduit.git
cd conduit
flutter pub get
dart run build_runner build
flutter run -d ios   # or: flutter run -d android
```

## Contributing

Bugs go to [GitHub Issues](https://github.com/cogwheel0/conduit/issues). Features
and questions go to [GitHub Discussions](https://github.com/cogwheel0/conduit/discussions).
Open an issue or discussion before sending a pull request.

## License

Released under the [GPL-3.0 License](LICENSE). Conduit is an independent client
and is not affiliated with Open WebUI.
