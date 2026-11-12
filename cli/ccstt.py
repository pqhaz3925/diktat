#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=13"]
# ///
"""ccstt — speech-to-text via Claude Code's voice_stream endpoint (wss://api.anthropic.com/api/ws/speech_to_text/voice_stream).

Протокол снят с Claude Code 2.1.322 (chunk с CXo/vXo, useVoice):
  * WS GET {BASE_API_URL→wss}/api/ws/speech_to_text/voice_stream?encoding=linear16&sample_rate=16000&channels=1
        &endpointing_ms=300&utterance_end_ms=1000&language=<код>&use_conversation_engine=true[&forward_interims=typed]
  * заголовки: Authorization: Bearer <claude.ai OAuth access token>, x-app: cli, User-Agent: claude-cli/...,
        anthropic-client-platform, x-config-keyterms: "term1,term2,..." (ASCII, ≤1024 симв., без запятых внутри)
  * клиент → сервер: бинарные кадры PCM s16le 16 кГц моно; текст {"type":"KeepAlive"} сразу и каждые 8 с;
        {"type":"CloseStream"} в конце
  * сервер → клиент: {"type":"TranscriptInterim"|"TranscriptText","data":"..."} — текущая гипотеза сегмента,
        {"type":"TranscriptEndpoint"} — сегмент закончен (последний interim становится финалом),
        {"type":"TranscriptError","description"/"error_code"}, {"type":"error","message"}

Использование:
  ccstt file.m4a [-l ru] [-k "Kubernetes,Helm"] [--keyterms-file terms.txt]   # файл (через ffmpeg)
  ccstt [-l ru]                                                              # микрофон, Enter/Ctrl+C — стоп
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import platform
import re
import subprocess
import sys
import time
from urllib.parse import urlencode

import websockets

BASE = os.environ.get("CCSTT_BASE_URL", "https://api.anthropic.com")
PATH = "/api/ws/speech_to_text/voice_stream"
RATE = 16000
BYTES_PER_SEC = RATE * 2
KEEPALIVE = json.dumps({"type": "KeepAlive"}, separators=(",", ":"))
CLOSE = json.dumps({"type": "CloseStream"}, separators=(",", ":"))
CC_VERSION = os.environ.get("CCSTT_CC_VERSION", "2.1.322")

# Тот же базовый словарь, что вшит в Claude Code; дополняется своими терминами.
DEFAULT_TERMS = ["MCP", "symlink", "grep", "regex", "localhost", "codebase", "TypeScript", "JSON",
                 "OAuth", "webhook", "gRPC", "dotfiles", "subagent", "worktree"]


def get_token() -> str:
    if t := os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") or os.environ.get("CCSTT_TOKEN"):
        return t
    raw = None
    if sys.platform == "darwin":
        r = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                           capture_output=True, text=True)
        if r.returncode == 0:
            raw = r.stdout
    if raw is None:
        p = os.path.expanduser("~/.claude/.credentials.json")
        if os.path.exists(p):
            raw = open(p).read()
    if not raw:
        sys.exit("нет OAuth-токена: залогинься в claude (/login) или задай CLAUDE_CODE_OAUTH_TOKEN")
    o = json.loads(raw).get("claudeAiOauth") or {}
    if o.get("expiresAt") and o["expiresAt"] / 1000 < time.time():
        sys.exit("OAuth-токен протух — запусти `claude` разок, он обновит его в keychain")
    return o["accessToken"]


def pack_keyterms(terms: list[str]) -> str:
    # 1:1 с функцией H() из Claude Code: убрать запятые и не-ASCII, дедуп, ≤1024 символов
    seen, out, n = set(), [], 0
    for t in terms:
        p = re.sub(r"\s+", " ", re.sub(r"[^\x20-\x7E]", "", t.replace(",", " "))).strip()
        if not p or p in seen:
            continue
        add = len(p) + (1 if out else 0)
        if n + add > 1024:
            break
        seen.add(p); out.append(p); n += add
    return ",".join(out)


def build_url(lang: str, interims_typed: bool, endpointing_ms: int, utterance_end_ms: int) -> str:
    q = {"encoding": "linear16", "sample_rate": str(RATE), "channels": "1",
         "endpointing_ms": str(endpointing_ms), "utterance_end_ms": str(utterance_end_ms),
         "language": lang, "use_conversation_engine": "true"}
    if interims_typed:
        q["forward_interims"] = "typed"
    return BASE.replace("https://", "wss://").replace("http://", "ws://") + PATH + "?" + urlencode(q)


def ffmpeg_cmd(src: str | None) -> list[str]:
    base = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
    if src is None:  # микрофон
        if sys.platform == "darwin":
            dev = os.environ.get("CCSTT_MIC", ":default")
            inp = ["-f", "avfoundation", "-i", dev]
        else:
            inp = ["-f", "pulse", "-i", os.environ.get("CCSTT_MIC", "default")]
    else:
        inp = ["-i", src]
    return base + inp + ["-vn", "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-acodec", "pcm_s16le", "pipe:1"]


class Session:
    def __init__(self, live: bool):
        self.live = live
        self.finals: list[str] = []
        self.pending = ""
        self.last_msg = time.monotonic()
        self.endpoint_after_close = asyncio.Event()
        self.closing = False

    def _status(self, s: str):
        if self.live and sys.stderr.isatty():
            w = 100
            tail = s[-w:]
            sys.stderr.write("\r\033[K\033[2m" + tail + "\033[0m")
            sys.stderr.flush()

    def final(self, text: str):
        text = text.strip()
        if not text:
            return
        self.finals.append(text)
        if self.live and sys.stderr.isatty():
            sys.stderr.write("\r\033[K")
        print(text, flush=True)

    def on_msg(self, raw):
        self.last_msg = time.monotonic()
        try:
            m = json.loads(raw)
        except Exception:
            return
        t = m.get("type")
        if t in ("TranscriptInterim", "TranscriptText"):
            if m.get("data"):
                self.pending = m["data"]
                self._status(self.pending)
        elif t == "TranscriptEndpoint":
            s, self.pending = self.pending, ""
            self.final(s)
            if self.closing:
                self.endpoint_after_close.set()
        elif t == "TranscriptError":
            print(f"[TranscriptError] {m.get('description') or m.get('error_code')}", file=sys.stderr)
        elif t == "error":
            print(f"[server error] {m.get('message') or m}", file=sys.stderr)
        elif os.environ.get("CCSTT_DEBUG"):
            print(f"[msg] {m}", file=sys.stderr)

    def flush_pending(self):
        s, self.pending = self.pending, ""
        self.final(s)


async def run(args) -> int:
    terms = [] if args.no_default_terms else list(DEFAULT_TERMS)
    if args.keyterms:
        terms += [x for x in re.split(r"[,\n]", args.keyterms) if x.strip()]
    if args.keyterms_file:
        terms += [x for x in open(os.path.expanduser(args.keyterms_file)).read().splitlines()
                  if x.strip() and not x.lstrip().startswith("#")]
    headers = {
        "Authorization": f"Bearer {get_token()}",
        "User-Agent": f"claude-cli/{CC_VERSION} (external, cli)",
        "x-app": "cli",
        "anthropic-client-platform": {"darwin": "macos", "linux": "linux"}.get(sys.platform, platform.system().lower()),
    }
    kt = pack_keyterms(terms)
    if kt:
        headers["x-config-keyterms"] = kt
    url = build_url(args.language, not args.no_typed_interims, args.endpointing_ms, args.utterance_end_ms)
    if os.environ.get("CCSTT_DEBUG"):
        print(f"[url] {url}\n[keyterms] {kt}", file=sys.stderr)

    live = args.file is None
    sess = Session(live=live or args.show_interims)
    proc = await asyncio.create_subprocess_exec(*ffmpeg_cmd(args.file), stdout=asyncio.subprocess.PIPE)

    try:
        ws = await websockets.connect(url, additional_headers=headers, max_size=None, open_timeout=15,
                                      ping_interval=None)
    except websockets.InvalidStatus as e:
        proc.kill()
        print(f"upgrade rejected: HTTP {e.response.status_code} {e.response.body[:300]!r}", file=sys.stderr)
        return 2

    stop = asyncio.Event()

    async def keepalive():
        await ws.send(KEEPALIVE)
        while True:
            await asyncio.sleep(8)
            await ws.send(KEEPALIVE)

    async def reader():
        try:
            async for raw in ws:
                sess.on_msg(raw)
        except websockets.ConnectionClosed:
            pass

    async def wait_enter():
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, sys.stdin.readline)
        stop.set()

    async def sender():
        # 100 мс кадры; для файла — с ускорением args.speed относительно реального времени
        chunk = BYTES_PER_SEC // 10
        t0 = time.monotonic(); sent = 0
        while not stop.is_set():
            buf = await proc.stdout.read(chunk)
            if not buf:
                break
            await ws.send(buf)
            sent += len(buf)
            if not live and args.speed > 0:
                ahead = sent / BYTES_PER_SEC / args.speed - (time.monotonic() - t0)
                if ahead > 0:
                    await asyncio.sleep(ahead)
        if args.file:
            dur = sent / BYTES_PER_SEC
            print(f"[audio {dur:.1f}s sent in {time.monotonic()-t0:.1f}s]", file=sys.stderr)

    ka = asyncio.create_task(keepalive())
    rd = asyncio.create_task(reader())
    if live:
        print("🎙  говори; Enter — стоп", file=sys.stderr)
        asyncio.create_task(wait_enter())
    try:
        await sender()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        if proc.returncode is None:
            proc.terminate()

    # finalize: как в CC — CloseStream, ждём endpoint (или тишину/таймаут), лишний interim превращаем в финал
    sess.closing = True
    try:
        await ws.send(CLOSE)
    except websockets.ConnectionClosed:
        pass
    deadline = time.monotonic() + args.final_timeout
    while time.monotonic() < deadline and not rd.done():
        if sess.endpoint_after_close.is_set() and not sess.pending:
            break
        if time.monotonic() - sess.last_msg > 3.0 and not sess.pending:
            break
        await asyncio.sleep(0.1)
    sess.flush_pending()
    ka.cancel()
    await ws.close()
    if args.output:
        with open(args.output, "w") as f:
            f.write("\n".join(sess.finals) + "\n")
    return 0


def main():
    ap = argparse.ArgumentParser(description="STT через voice_stream Claude Code")
    ap.add_argument("file", nargs="?", help="аудио/видео файл (что угодно, что ест ffmpeg); без него — микрофон")
    ap.add_argument("-l", "--language", default=os.environ.get("CCSTT_LANG", "ru"),
                    help="en es fr ja de pt it ko hi id ru pl tr nl uk el cs da sv no (по умолчанию ru)")
    ap.add_argument("-k", "--keyterms", help="термины через запятую (только ASCII — CC вырезает остальное)")
    ap.add_argument("-K", "--keyterms-file", default=os.environ.get("CCSTT_KEYTERMS_FILE"),
                    help="файл с терминами, по одному на строку")
    ap.add_argument("--no-default-terms", action="store_true", help="не добавлять базовый словарь Claude Code")
    ap.add_argument("-o", "--output", help="записать итоговый текст в файл")
    ap.add_argument("--speed", type=float, default=float(os.environ.get("CCSTT_SPEED", "4")),
                    help="во сколько раз быстрее реального времени слать файл (0 = без ограничения)")
    ap.add_argument("--show-interims", action="store_true", help="показывать промежуточные гипотезы для файла")
    ap.add_argument("--no-typed-interims", action="store_true", help="не слать forward_interims=typed")
    ap.add_argument("--endpointing-ms", type=int, default=300)
    ap.add_argument("--utterance-end-ms", type=int, default=1000)
    ap.add_argument("--final-timeout", type=float, default=8.0)
    args = ap.parse_args()
    try:
        sys.exit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
