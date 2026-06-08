# codex.koplugin

**ChatGPT inside [KOReader](https://github.com/koreader/koreader), signed in with your ChatGPT subscription — no API key, no per-token billing.**

It reuses the exact OAuth client and backend that the official [OpenAI Codex CLI](https://github.com/openai/codex) uses, so it rides your ChatGPT Plus/Pro plan instead of the pay-as-you-go API.

> [!WARNING]
> **Unofficial.** This drives OpenAI's Codex OAuth client and the `chatgpt.com/backend-api/codex` backend from a third-party app. It is not endorsed by OpenAI, may break at any time, and is against the spirit of the ToS. Use it on **your own account only** and don't rely on it for anything important.

---

## Features

- **Sign in with ChatGPT** via the device-code flow — approve on your phone/computer, no API key, no browser or callback server on the device.
- **Chat** — real multi-turn conversations. Every answer has **Reply** (keeps context) and **New chat**.
- **Ask about highlighted text** — select any passage and choose **Explain / Summarize / Define terms / Ask about this…**, then keep the thread going.
- **Persistent history** — past chats are saved on device (last 50), reopen and continue any of them.
- **Web search** toggle — uses the backend's hosted `web_search` tool so answers can use live internet results.
- **Thinking level** — reasoning effort from `minimal` to `xhigh`.
- **Model picker** — `gpt-5.5` (default), `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, or a custom id.
- Tokens stored on device and auto-refreshed. WiFi is requested automatically when off (standard KOReader flow).

## Requirements

- KOReader (developed against the Kobo 2026.03 build; should work on any recent build).
- An active **ChatGPT Plus/Pro** subscription.

## Install

Copy the `codex.koplugin/` folder into your KOReader `plugins/` directory:

| Device | Path |
| --- | --- |
| **Kobo** | `.adds/koreader/plugins/codex.koplugin/` |
| **Kindle** | `koreader/plugins/codex.koplugin/` |
| **Other** | `<koreader>/plugins/codex.koplugin/` |

```bash
# clone and copy (Kobo example)
git clone https://github.com/lolwierd/codex.koplugin.git
cp -R codex.koplugin "/path/to/KOBOeReader/.adds/koreader/plugins/"
```

Then **fully restart KOReader** (exit and relaunch, not just back out).

## Usage

1. **Sign in** — main menu → **Codex (ChatGPT) → Sign in with ChatGPT**. Open the shown URL (`auth.openai.com/codex/device`) on your phone/computer and enter the one-time code. The device polls and stores the tokens.
2. **Chat** — **Codex (ChatGPT) → Chat with Codex…**, type a question. Use **Reply** to follow up.
3. **From a book** — highlight text → **Ask Codex** → pick an action.
4. **History** — **Codex (ChatGPT) → Chat history** to reopen past conversations.

Tweak **Model**, **Thinking**, and **Web search** from the same menu.

## How the auth works

Identical to the Codex CLI (and `pi`):

| | |
|---|---|
| Client ID | `app_EMoamEEZ73f0CkXaXp7hrann` |
| Issuer | `https://auth.openai.com` |
| Device usercode | `POST /api/accounts/deviceauth/usercode` |
| Device poll | `POST /api/accounts/deviceauth/token` (403/404 = pending) |
| Token exchange | `POST /oauth/token` — `grant_type=authorization_code`; the server returns the PKCE verifier in the device flow, so no local crypto is needed |
| Refresh | `POST /oauth/token` — `grant_type=refresh_token` |
| API | `POST https://chatgpt.com/backend-api/codex/responses` (SSE) |
| Headers | `Authorization: Bearer …`, `chatgpt-account-id: …`, `OpenAI-Beta: responses=experimental`, `originator: codex_cli_rs` |

`chatgpt-account-id` is read from the `https://api.openai.com/auth` → `chatgpt_account_id` claim in the token JWT.

## File layout

| File | Purpose |
| --- | --- |
| `main.lua` | Menu, highlight integration, login UI, conversation engine, history |
| `codexauth.lua` | Device-code login, token store/refresh, JWT decode |
| `codexapi.lua` | `/responses` request + JSON/SSE parsing |
| `_meta.lua` | Plugin metadata |

On-device data:

- `koreader/settings/codex_auth.lua` — tokens (`access`, `refresh`, `expires`, `account_id`)
- `koreader/settings/codex_config.lua` — model / thinking / web-search prefs
- `koreader/settings/codex_chats.lua` — chat history

## Caveats

- **Unofficial / ToS-gray** (see the warning above). `originator` is set to `codex_cli_rs` so requests look like the sanctioned client.
- **Models** are whatever the Codex backend serves; availability depends on your plan. If a model or thinking level is rejected, the popup says so — switch in the menu.
- **Web search** uses the hosted tool; Codex's own source notes it occasionally errors despite being documented. If answers fail with it on, turn it off or change model.
- Requests currently run **inline** (the screen briefly freezes while waiting). Long answers are capped at a generous request timeout.

## Credits

- [KOReader](https://github.com/koreader/koreader)
- Auth/endpoint design mirrors the [OpenAI Codex CLI](https://github.com/openai/codex).

## License

Released into the public domain under [The Unlicense](https://unlicense.org). See [LICENSE](LICENSE).

Personal project. No warranty. Use at your own risk.
