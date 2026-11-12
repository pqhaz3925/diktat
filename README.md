# Diktat

A tiny macOS menu-bar dictation app (plus a CLI) that uses the same speech-to-text backend as
**Claude Code's `/voice` mode** — with your own list of key terms, so `vLLM`, `CUDA`, `nginx ingress`
come out spelled right instead of "в LLM" or "Q the".

- Global hotkey (toggle or hold-to-talk), floating live-transcript pill, result goes to the clipboard
  (optionally auto-pasted into the front app)
- Drop any audio/video file on the menu to transcribe it (AVFoundation; ffmpeg fallback for ogg/opus/webm)
- 20 languages, including Russian; custom key terms (keyterm prompting)
- No dependencies, ~1 MB, Swift/SwiftUI, macOS 14+

> **Unofficial.** This talks to an undocumented endpoint that Claude Code uses internally
> (`/api/ws/speech_to_text/voice_stream`) with the OAuth token Claude Code stores after `/login`.
> It requires a Claude.ai Pro/Max subscription, is not affiliated with or endorsed by Anthropic,
> and may stop working at any time. Check that your use complies with Anthropic's terms.

## Requirements

- macOS 14+
- [Claude Code](https://claude.com/claude-code) installed and logged in with a Claude.ai account
  (`claude` → `/login`). Diktat reads the token from the keychain item `Claude Code-credentials`
  (or `~/.claude/.credentials.json`, or `$CLAUDE_CODE_OAUTH_TOKEN`). If the token expired, just run `claude` once.
- Optional: `ffmpeg` for formats AVFoundation can't read (Telegram voice notes etc.)

## Build

```sh
./scripts/build-app.sh          # → build/Diktat.app (universal, ad-hoc signed)
open build/Diktat.app
```

Default hotkey is **⌃⌥Space**. Change it, the language and key terms in the menu → Settings.
Auto-paste needs Accessibility permission (System Settings → Privacy & Security → Accessibility).

## CLI

`cli/ccstt.py` is a standalone Python version (runs via [uv](https://github.com/astral-sh/uv), needs ffmpeg):

```sh
cli/ccstt.py meeting.m4a -l ru -k "Kubernetes,Helm,vLLM" -o meeting.txt
cli/ccstt.py -K terms.txt talk.mp4
cli/ccstt.py                      # microphone, Enter to stop
```

## Protocol

Reverse-engineered from Claude Code 2.1.x. The backend looks like Deepgram (Nova-3 style keyterm prompting)
behind Anthropic's proxy.

```
GET wss://api.anthropic.com/api/ws/speech_to_text/voice_stream
      ?encoding=linear16&sample_rate=16000&channels=1
      &endpointing_ms=300&utterance_end_ms=1000
      &language=ru&use_conversation_engine=true&forward_interims=typed
Authorization: Bearer <claude.ai OAuth access token>
x-app: cli
User-Agent: claude-cli/<version> (external, cli)
anthropic-client-platform: macos
x-config-keyterms: vLLM,CUDA,nginx ingress      # ASCII, comma-separated, ≤1024 chars

→ binary   PCM s16le 16 kHz mono
→ text     {"type":"KeepAlive"}   on open and every 8 s
→ text     {"type":"CloseStream"} when done
← {"type":"TranscriptInterim"|"TranscriptText","data":"…"}   current hypothesis for the segment
← {"type":"TranscriptEndpoint"}                              segment finished → last hypothesis is final
← {"type":"TranscriptError","description":…} / {"type":"error","message":…}
```

Notes:
- Claude Code always adds these terms: `MCP symlink grep regex localhost codebase TypeScript JSON OAuth
  webhook gRPC dotfiles subagent worktree`, plus the project folder name and words from the git branch.
  The built-ins can hurt (e.g. "GRE" → "grep"), so they can be turned off.
- Non-ASCII key terms are stripped by Claude Code's client; write terms in the Latin spelling you want to see.
- Files can be streamed at ~4× realtime reliably; unthrottled uploads lose the tail of the audio.
- Supported languages: en es fr ja de pt it ko hi id ru pl tr nl uk el cs da sv no.

## License

MIT
