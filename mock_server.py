"""Local mock of the Anthropic Messages API.

Serves fake responses so Claude Code CLI can be driven without spending credits.
Run with:  uv run mock_server.py
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import random
import re
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator

import uvicorn
import yaml
from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

BASE_DIR = Path(__file__).resolve().parent
RESPONSES_PATH = BASE_DIR / "responses.yaml"
LOG_DIR = BASE_DIR / "logs"
SCRIPTS_DIR = BASE_DIR / "scripts"

# Echoed back when a request omits `model`. A real id keeps the CLI's header,
# status line and /model output looking like an ordinary session.
DEFAULT_MODEL = "claude-opus-4-8"

load_dotenv(BASE_DIR / ".env")


# --------------------------------------------------------------------------- config


def parse_duration(raw: str | None) -> float | None:
    """`30s` / `5m` / `1h` / `90` -> seconds. `unlimited` -> None."""
    if raw is None:
        return None
    value = raw.strip().lower()
    if value in ("", "unlimited", "none", "infinite", "inf", "0"):
        return None
    match = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([smh]?)", value)
    if not match:
        raise ValueError(f"FAKE_DURATION: cannot parse {raw!r} (use 30s, 5m, 1h, 90, or unlimited)")
    amount = float(match.group(1))
    return amount * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2)]


def env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default


def env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() not in ("0", "false", "no", "off", "")


@dataclass(frozen=True)
class Config:
    host: str
    port: int
    duration: float | None  # None == unlimited
    chunk_delay: float  # seconds between text deltas
    turn_delay: float  # seconds between simulated agentic turns
    think_min: float  # shortest "thinking" pause before a response
    think_max: float  # longest "thinking" pause before a response
    script_loop: bool  # restart a script from the top once it runs out
    log_bodies: bool  # dump every request body to logs/ (off by default)

    @property
    def duration_label(self) -> str:
        return "unlimited" if self.duration is None else f"{self.duration:g}s"

    @property
    def think_label(self) -> str:
        return f"{self.think_min:g}-{self.think_max:g}s"

    def think_delay(self) -> float:
        """A fresh random pause length, so turns don't feel metronomic."""
        return random.uniform(self.think_min, self.think_max)


def _think_bounds() -> tuple[float, float]:
    low = env_int("THINK_MIN_MS", 5_000) / 1000
    high = env_int("THINK_MAX_MS", 7_000) / 1000
    return (high, low) if low > high else (low, high)


_THINK_MIN, _THINK_MAX = _think_bounds()

CONFIG = Config(
    host=os.getenv("HOST", "127.0.0.1"),
    port=env_int("PORT", 8787),
    duration=parse_duration(os.getenv("FAKE_DURATION", "unlimited")),
    chunk_delay=env_int("CHUNK_DELAY_MS", 40) / 1000,
    turn_delay=env_int("TURN_DELAY_MS", 500) / 1000,
    think_min=_THINK_MIN,
    think_max=_THINK_MAX,
    script_loop=env_bool("SCRIPT_LOOP", True),
    log_bodies=env_bool("FAKE_LOG_BODIES", False),
)


# --------------------------------------------------------------------------- sessions


@dataclass
class Session:
    id: str
    started_at: float = field(default_factory=time.monotonic)
    # Touched on every request the session is looked up for. A run that lasts
    # days would otherwise accumulate a Session per hashed conversation forever.
    last_seen: float = field(default_factory=time.monotonic)
    turns: int = 0
    # How far into each script this session has played, so a follow-up message
    # continues the transcript instead of restarting it.
    cursors: dict[str, int] = field(default_factory=dict)

    def cursor(self, script: str) -> int:
        return self.cursors.get(script, 0)

    def advance(self, script: str, by: int = 1) -> None:
        self.cursors[script] = self.cursor(script) + by

    def rewind(self, script: str, by: int = 1) -> None:
        """Replay a segment on the next request — used to park on a tool call
        until its tool_result comes back."""
        self.cursors[script] = max(0, self.cursor(script) - by)

    @property
    def remaining(self) -> float | None:
        if CONFIG.duration is None:
            return None
        return max(0.0, CONFIG.duration - (time.monotonic() - self.started_at))

    @property
    def expired(self) -> bool:
        return self.remaining is not None and self.remaining <= 0

    @property
    def remaining_label(self) -> str:
        return "unlimited" if self.remaining is None else f"{self.remaining:.1f}s"


SESSIONS: dict[str, Session] = {}


# --------------------------------------------------------------------------- events


# The driver runs in its own terminal, so it can't watch the CLI's output to
# know what's happening. The server can: it's the thing deciding when a tool
# call goes out and when a turn ends. Those two moments are published here and
# consumed over GET /events.
EVENT_SUBSCRIBERS: set[asyncio.Queue[str]] = set()


def publish(event: str, **fields: Any) -> None:
    # Compact separators: the driver matches these lines with shell globs, so
    # `{"event":"turn_end"` has to stay literal — json.dumps' default `", "` /
    # `": "` spacing would silently stop matching.
    payload = json.dumps({"event": event, "at": time.time(), **fields}, separators=(",", ":"))
    for queue in EVENT_SUBSCRIBERS:
        # Drop rather than block: a driver that stopped reading must never
        # stall the response stream the CLI is waiting on.
        if queue.qsize() < 64:
            queue.put_nowait(payload)


def session_for(body: dict[str, Any]) -> Session:
    """One budget per agentic run, keyed so a multi-turn tool loop stays in it."""
    metadata = body.get("metadata") or {}
    key = metadata.get("user_id")
    if key:
        # The CLI packs a JSON blob into user_id. Key on the session_id inside
        # it — same grouping, but a log line you can actually read.
        try:
            key = json.loads(key).get("session_id") or key
        except (json.JSONDecodeError, AttributeError):
            pass
        session = SESSIONS.setdefault(key, Session(id=str(key)[:12]))
    else:
        messages = body.get("messages") or []
        seed = json.dumps(messages[0], sort_keys=True) if messages else "empty"
        key = hashlib.sha1(seed.encode()).hexdigest()[:12]
        session = SESSIONS.setdefault(key, Session(id=str(key)))
    session.last_seen = time.monotonic()
    return session


# --------------------------------------------------------------------------- rules


def load_rules() -> list[dict[str, Any]]:
    """Re-read on every request so responses.yaml can be edited live."""
    try:
        data = yaml.safe_load(RESPONSES_PATH.read_text()) or {}
    except (OSError, yaml.YAMLError) as exc:
        log(f"responses.yaml unreadable ({exc}) — falling back to built-in default")
        return []
    return data.get("rules") or []


# --------------------------------------------------------------------------- scripts


@dataclass
class Segment:
    """One turn of a scripted transcript: thinking, then the reply it produced.

    A segment may also carry a tool call, which splits the turn in two: the CLI
    gets thinking + tool_use, shows its permission prompt, and only after the
    tool_result comes back does the response half play.
    """

    thinking: str
    response: str
    tool: dict[str, Any] | None = None


BLOCK_RE = re.compile(r"^\[\[(thinking|tool_use|response)\]\]\s*$", re.MULTILINE)


def parse_tool_block(body: str, where: str) -> dict[str, Any] | None:
    """A [[tool_use]] body is YAML: `name:` plus an optional `input:` mapping."""
    try:
        data = yaml.safe_load(body) or {}
    except yaml.YAMLError as exc:
        log(f"{where}: [[tool_use]] is not valid YAML ({exc}) — ignoring")
        return None
    if not isinstance(data, dict) or not data.get("name"):
        log(f"{where}: [[tool_use]] needs a `name:` — ignoring")
        return None
    tool_input = data.get("input")
    return {"name": str(data["name"]), "input": tool_input if isinstance(tool_input, dict) else {}}


def parse_script(text: str, where: str = "script") -> list[Segment]:
    """Split a script file into [[thinking]] / [[tool_use]] / [[response]] blocks.

    Anything before the first marker is treated as a header comment and dropped,
    so scripts can carry a `# title` line without it leaking into output. A
    [[response]] closes the segment; thinking and tool_use accumulate into it.
    """
    parts = BLOCK_RE.split(text)[1:]  # drop the preamble
    thinking = ""
    tool: dict[str, Any] | None = None
    segments: list[Segment] = []
    for kind, chunk in zip(parts[::2], parts[1::2]):
        body = chunk.strip()
        if kind == "thinking":
            thinking = body
        elif kind == "tool_use":
            tool = parse_tool_block(body, where)
        else:
            segments.append(Segment(thinking=thinking, response=body, tool=tool))
            thinking = ""
            tool = None
    return segments


def load_script(name: str) -> list[Segment] | None:
    """Resolve `@1`, `@1.md`, `@scripts/1.md` → scripts/1.md. Re-read per request."""
    stem = Path(name).name
    if stem.endswith(".md"):
        stem = stem[:-3]
    if not stem or "/" in stem or stem.startswith("."):
        return None
    path = SCRIPTS_DIR / f"{stem}.md"
    try:
        segments = parse_script(path.read_text(), where=path.name)
    except OSError:
        return None
    if not segments:
        log(f"script {path.name} has no [[thinking]]/[[response]] blocks")
        return None
    return segments


MENTION_RE = re.compile(r"@([A-Za-z0-9_\-./]+)")


def script_for(message: str) -> tuple[str, list[Segment]] | None:
    """First @mention in the message that resolves to a script file."""
    for name in MENTION_RE.findall(message):
        segments = load_script(name)
        if segments:
            return Path(name).name.removesuffix(".md"), segments
    return None


def script_for_body(body: dict[str, Any]) -> tuple[str, list[Segment]] | None:
    """The script this conversation is playing, newest mention first.

    Only the opening message carries the @mention — once a tool call is in
    flight the latest user message is a tool_result — so the whole history is
    searched rather than just the last turn.
    """
    for message in reversed(body.get("messages") or []):
        if message.get("role") != "user":
            continue
        found = script_for(text_of(message.get("content")))
        if found:
            return found
    return None


@dataclass
class Playlist:
    """Walks a script's segments, remembering position across turns."""

    label: str
    key: str
    segments: list[Segment]
    session: Session
    loop: bool
    _last: int = 0
    _wrapped: bool = False

    def next(self) -> Segment:
        i = self.session.cursor(self.key)
        self._last = i % len(self.segments)
        self.session.advance(self.key)
        if self._last == len(self.segments) - 1:
            self._wrapped = True
        return self.segments[self._last]

    def park(self) -> None:
        """Stay on the segment just handed out, so the next request replays it."""
        self.session.rewind(self.key)
        self._wrapped = self._wrapped and self._last != len(self.segments) - 1

    @property
    def position(self) -> str:
        return f"{self._last + 1}/{len(self.segments)}"

    @property
    def exhausted(self) -> bool:
        """Played every segment once, and not configured to start over."""
        return self._wrapped and not self.loop


def playlist_for(body: dict[str, Any], rule: dict[str, Any], session: Session) -> Playlist:
    """A scripted transcript if the conversation @-references one, else the yaml rule."""
    found = script_for_body(body)
    if found:
        name, segments = found
        return Playlist(
            label=f"script @{name}", key=f"script:{name}", segments=segments, session=session, loop=CONFIG.script_loop
        )
    segment = Segment(thinking=str(rule.get("thinking", "")), response=str(rule.get("response", "")))
    return Playlist(label="responses.yaml", key="rule", segments=[segment], session=session, loop=True)


def pick_rule(rules: list[dict[str, Any]], last_user_message: str) -> dict[str, Any]:
    default: dict[str, Any] | None = None
    for rule in rules:
        pattern = rule.get("match")
        if pattern is None:
            default = default or rule
            continue
        if pattern.lower() in last_user_message.lower():
            return rule
        try:
            if re.search(pattern, last_user_message, re.IGNORECASE):
                return rule
        except re.error:
            pass
    return default or {"response": "This is a fake response from the local mock server."}


def text_of(content: Any) -> str:
    """Flatten Anthropic content (string or block list) to plain text."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            parts.append(str(block.get("text", "")))
        elif block.get("type") == "tool_result":
            parts.append(text_of(block.get("content")))
    return "\n".join(p for p in parts if p)


def last_user_text(body: dict[str, Any]) -> str:
    for message in reversed(body.get("messages") or []):
        if message.get("role") == "user":
            return text_of(message.get("content")).strip()
    return ""


# Prompts the CLI writes on the user's behalf. They are indistinguishable from a
# real turn by shape — same tools, same session — so they have to be matched on
# their text. Left unhandled, the recap below fires on its own after a few idle
# minutes, eats a script segment and publishes a turn_end nobody asked for,
# which makes the driver type over a response that is still streaming.
#
# One entry, because one is all that has actually been observed in logs/. Add to
# it the same way: find a request whose last user message is neither an
# @mention nor a tool_result, and match its opening words.
CLI_PROBE_RE = re.compile(r"^\s*The user stepped away and is coming back", re.IGNORECASE)


def is_agent_request(body: dict[str, Any]) -> bool:
    """True for the actual conversation turn, false for the CLI's side requests.

    Every prompt fires two calls: the real one, carrying the CLI's whole tool
    set, and a small tool-less one that asks for a conversation title. They are
    otherwise identical — same model, same session, same metadata — so `tools`
    is the discriminator for that pair. It is not sufficient on its own: the
    CLI also injects prompts of its own that *do* carry the tool set, so
    CLI_PROBE_RE has to rule those out too.

    Side requests must never consume a script segment or publish an event:
    doing so eats the transcript a turn at a time and makes the driver type
    over a response that is still streaming.
    """
    if not body.get("tools"):
        return False
    return not CLI_PROBE_RE.match(last_user_text(body))


def side_request_reply(body: dict[str, Any]) -> str:
    """A short, plausible answer for a side request (a title, or a CLI probe)."""
    text = MENTION_RE.sub("", last_user_text(body)).strip()
    # A probe asks for prose about the conversation, not a title of it —
    # echoing the first six words of the instruction back would be visible in
    # the transcript as the CLI's own prompt leaking through.
    if CLI_PROBE_RE.match(text):
        return "Picking up where we left off — still working through the issue you raised."
    # The prompt wraps the message in <session>…</session> — keep the inside.
    match = re.search(r"<session>(.*?)</session>", text, re.DOTALL)
    if match:
        text = match.group(1).strip()
    words = re.sub(r"[^\w\s-]", "", text).split()[:6]
    return " ".join(words).capitalize() or "New conversation"


def has_pending_tool_result(body: dict[str, Any]) -> bool:
    messages = body.get("messages") or []
    if not messages:
        return False
    content = messages[-1].get("content")
    if not isinstance(content, list):
        return False
    return any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)


# --------------------------------------------------------------------------- logging


def log(line: str) -> None:
    stamp = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{stamp}] {line}", flush=True)


def dump_body(path: str, body: dict[str, Any]) -> None:
    """Write one request body to logs/, if FAKE_LOG_BODIES asked for it.

    Off by default, and deliberately so. The CLI resends the whole transcript
    every turn, so bodies grow with the conversation — a few hundred KB early,
    over a megabyte by the end of a long run — and there is one per request.
    An unattended run left this on produced 140MB in six hours; on a host with
    a small ephemeral disk that ends as a failed write mid-run, which the CLI
    sees as a 500. Cost, not value: the one-line log above says what happened.
    """
    if not CONFIG.log_bodies:
        return
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%f")
    name = f"{stamp}_{path.strip('/').replace('/', '_') or 'root'}.json"
    try:
        LOG_DIR.mkdir(exist_ok=True)
        (LOG_DIR / name).write_text(json.dumps(body, indent=2, ensure_ascii=False))
    except OSError as exc:
        # A full disk must stay a logging problem, not a failed API request.
        log(f"could not write {name} ({exc}) — continuing")


def log_request(request: Request, body: dict[str, Any], session: Session | None) -> None:
    message = last_user_text(body).replace("\n", " ")
    if len(message) > 80:
        message = message[:77] + "..."
    log(
        f"{request.method} {request.url.path} "
        f"model={body.get('model', '-')} "
        f"stream={bool(body.get('stream'))} "
        f"session={session.id if session else '-'} "
        f"remaining={session.remaining_label if session else '-'} "
        f"msg={message!r}"
    )
    dump_body(request.url.path, body)


# --------------------------------------------------------------------------- SSE


def frame(event: str, data: dict[str, Any]) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode()


def chunk_text(text: str) -> list[str]:
    """Split into word-ish chunks so deltas look like real token streaming."""
    return re.findall(r"\S+\s*", text) or [text]


def new_message_id() -> str:
    return f"msg_{uuid.uuid4().hex[:24]}"


def message_start(message_id: str, model: str) -> dict[str, Any]:
    return {
        "type": "message_start",
        "message": {
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 1},
        },
    }


async def stream_tool_use(tool: dict[str, Any], index: int = 0) -> AsyncIterator[bytes]:
    tool_id = f"toolu_{uuid.uuid4().hex[:20]}"
    yield frame(
        "content_block_start",
        {
            "type": "content_block_start",
            "index": index,
            "content_block": {"type": "tool_use", "id": tool_id, "name": tool.get("name", "fake_tool"), "input": {}},
        },
    )
    payload = json.dumps(tool.get("input") or {}, ensure_ascii=False)
    for piece in [payload[i : i + 24] for i in range(0, len(payload), 24)]:
        yield frame(
            "content_block_delta",
            {
                "type": "content_block_delta",
                "index": index,
                "delta": {"type": "input_json_delta", "partial_json": piece},
            },
        )
        await asyncio.sleep(CONFIG.chunk_delay)
    yield frame("content_block_stop", {"type": "content_block_stop", "index": index})


THINKING_LINES = [
    "Let me look at what's actually being asked here.",
    "Checking the shape of the request before I answer.",
    "There are a couple of ways to go about this.",
    "Walking through the pieces one at a time.",
    "That mostly lines up with what I'd expect.",
    "Worth double-checking the edge case before I commit.",
    "Right — I think the straightforward path is fine here.",
    "Pulling the thread on that a little further.",
    "Nothing here contradicts the earlier assumption.",
    "Let me sanity-check the ordering once more.",
    "Okay, that settles which direction to take.",
    "Putting the answer together now.",
]


def filler_thinking(seconds: float, pace: float) -> str:
    """Enough generic thinking prose to fill `seconds` at roughly `pace` per chunk."""
    wanted = max(1, int(seconds / max(pace, 0.05)))
    pool = THINKING_LINES[:]
    random.shuffle(pool)
    picked: list[str] = []
    words = 0
    while words < wanted:
        line = pool[len(picked) % len(pool)]
        picked.append(line)
        words += len(line.split())
    return " ".join(picked)


async def stream_thinking(
    request: Request, session: Session, index: int, label: str, text: str = ""
) -> AsyncIterator[bytes]:
    """Stream a real `thinking` content block, paced to fill the whole gap.

    The CLI sends `thinking: {"type": "adaptive"}`, so it renders these blocks —
    which means the wait is visibly *thinking* rather than dead air.
    """
    seconds = CONFIG.think_delay()
    if session.remaining is not None:
        seconds = min(seconds, session.remaining)
    if seconds <= 0:
        return

    pace = 0.25
    chunks = chunk_text(text.strip() or filler_thinking(seconds, pace))
    # Scripted thinking has a fixed length, so pace it to fill the gap — but
    # never so slowly that it reads as stalled.
    delay = min(0.8, max(0.02, seconds / len(chunks)))
    log(f"session={session.id} {label} thinking for {seconds:.1f}s")

    yield frame(
        "content_block_start",
        {
            "type": "content_block_start",
            "index": index,
            "content_block": {"type": "thinking", "thinking": "", "signature": ""},
        },
    )
    deadline = time.monotonic() + seconds
    for chunk in chunks:
        if await request.is_disconnected() or time.monotonic() >= deadline:
            break
        yield frame(
            "content_block_delta",
            {"type": "content_block_delta", "index": index, "delta": {"type": "thinking_delta", "thinking": chunk}},
        )
        await asyncio.sleep(delay)
    yield frame(
        "content_block_delta",
        {
            "type": "content_block_delta",
            "index": index,
            "delta": {"type": "signature_delta", "signature": uuid.uuid4().hex},
        },
    )
    yield frame("content_block_stop", {"type": "content_block_stop", "index": index})


async def stream_messages(request: Request, body: dict[str, Any], session: Session) -> AsyncIterator[bytes]:
    model = body.get("model", DEFAULT_MODEL)
    message = last_user_text(body)

    # Answer side requests immediately and get out: no thinking pause, no
    # segment consumed, no events. See is_agent_request().
    if not is_agent_request(body):
        reply = side_request_reply(body)
        log(f"session={session.id} side request — replying {reply!r}")
        yield frame("message_start", message_start(new_message_id(), model))
        yield frame(
            "content_block_start",
            {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        )
        yield frame(
            "content_block_delta",
            {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": reply}},
        )
        yield frame("content_block_stop", {"type": "content_block_stop", "index": 0})
        yield frame(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 1},
            },
        )
        yield frame("message_stop", {"type": "message_stop"})
        return

    rule = pick_rule(load_rules(), message)
    playlist = playlist_for(body, rule, session)
    tool = rule.get("tool_use")
    # An @script always wins over a tool_use rule — it's an explicit request.
    emit_tool = (
        bool(tool)
        and not playlist.key.startswith("script:")
        and not has_pending_tool_result(body)
        and not session.expired
    )
    message_id = new_message_id()
    session.turns += 1
    log(f"session={session.id} playing {playlist.label} from segment {session.cursor(playlist.key) + 1}")

    # Every path out of the block below has to publish exactly one event. The
    # driver is blocked on this stream: it presses Enter on tool_use and types
    # the next prompt on turn_end, and does nothing at all otherwise. A turn
    # that ends without saying so — the client hung up mid-stream, the task was
    # cancelled — used to leave it waiting on an event that was never coming.
    settled = False
    try:
        yield frame("message_start", message_start(message_id, model))
        index = 0

        if emit_tool:
            async for out in stream_thinking(request, session, index, "pre-tool", str(rule.get("thinking", ""))):
                yield out
            index += 1
            if await request.is_disconnected():
                log(f"client disconnected (session={session.id}) — closing stream")
                return
            async for out in stream_tool_use(tool, index):
                yield out
            publish("tool_use", session=session.id, tool=str(tool.get("name", "fake_tool")))
            settled = True
            stop_reason = "tool_use"
        else:
            turn = 0
            stop_reason = "end_turn"
            resuming = has_pending_tool_result(body)
            while True:
                segment = playlist.next()
                turn += 1

                # Each segment: think first, then deliver the reply it produced.
                # Coming back from a tool_result the thinking already played, so
                # go straight to the response half of the segment.
                if not resuming:
                    async for out in stream_thinking(
                        request, session, index, f"{playlist.label} seg {playlist.position}", segment.thinking
                    ):
                        yield out
                    index += 1
                    if await request.is_disconnected():
                        log(f"client disconnected (session={session.id}) — closing stream")
                        return
                    if session.expired:
                        break

                # A scripted tool call ends the message: the CLI has to run the
                # tool and come back with a tool_result before the reply makes
                # sense. Park on this segment so the response half plays then.
                if segment.tool and not resuming:
                    log(f"session={session.id} {playlist.label} seg {playlist.position} tool_use {segment.tool['name']}")
                    async for out in stream_tool_use(segment.tool, index):
                        yield out
                    playlist.park()
                    publish("tool_use", session=session.id, tool=segment.tool["name"])
                    settled = True
                    stop_reason = "tool_use"
                    break
                resuming = False

                # One text block per segment, so each reply stands on its own.
                yield frame(
                    "content_block_start",
                    {"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}},
                )
                for chunk in chunk_text(segment.response or "…"):
                    if await request.is_disconnected():
                        log(f"client disconnected (session={session.id}) — closing stream")
                        return
                    yield frame(
                        "content_block_delta",
                        {
                            "type": "content_block_delta",
                            "index": index,
                            "delta": {"type": "text_delta", "text": chunk},
                        },
                    )
                    await asyncio.sleep(CONFIG.chunk_delay)
                yield frame("content_block_stop", {"type": "content_block_stop", "index": index})
                index += 1

                log(
                    f"session={session.id} {playlist.label} segment {playlist.position} delivered "
                    f"(turn {turn}), remaining={session.remaining_label}"
                )
                if session.expired:
                    break
                # Not enough budget left to think *and* answer — stop on a
                # response rather than trailing a thinking block with nothing after it.
                if session.remaining is not None and session.remaining < CONFIG.think_min:
                    log(f"session={session.id} too little budget for another segment — finishing")
                    break
                if playlist.exhausted:
                    log(f"session={session.id} {playlist.label} complete")
                    break
                # Nothing bounds the loop when the budget is unlimited, and the
                # driver can't see a turn end that never comes — one segment per
                # request, same as the non-streaming path.
                if session.remaining is None:
                    break

        yield frame(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": 1},
            },
        )
        yield frame("message_stop", {"type": "message_stop"})
        log(f"session={session.id} turn={session.turns} finished stop_reason={stop_reason}")
        if stop_reason != "tool_use":
            publish("turn_end", session=session.id, turn=session.turns)
            settled = True
    except asyncio.CancelledError:
        log(f"stream cancelled (session={session.id})")
        raise
    finally:
        if not settled:
            log(f"session={session.id} turn={session.turns} ended without finishing — publishing turn_abort")
            publish("turn_abort", session=session.id, turn=session.turns)


# --------------------------------------------------------------------------- app


# A session nobody has touched for this long is over: the CLI was restarted, or
# the conversation was cleared. Keeping it costs memory in a process that is
# meant to stay up for days.
SESSION_TTL = 3600


async def report_remaining() -> None:
    while True:
        await asyncio.sleep(15)
        now = time.monotonic()
        for key, session in list(SESSIONS.items()):
            if now - session.last_seen > SESSION_TTL:
                del SESSIONS[key]
                log(f"session={session.id} idle for {SESSION_TTL}s — forgetting it")
                continue
            if CONFIG.duration is not None and not session.expired:
                log(f"session={session.id} budget remaining={session.remaining_label}")


@asynccontextmanager
async def lifespan(_: FastAPI):
    log("fake-claude mock Anthropic API")
    log(f"  listening      http://{CONFIG.host}:{CONFIG.port}")
    log(f"  FAKE_DURATION  {CONFIG.duration_label}")
    log(f"  CHUNK_DELAY_MS {CONFIG.chunk_delay * 1000:g}")
    log(f"  TURN_DELAY_MS  {CONFIG.turn_delay * 1000:g}")
    log(f"  THINK_DELAY    {CONFIG.think_label} (random, before each response)")
    log(f"  SCRIPT_LOOP    {'on' if CONFIG.script_loop else 'off'}")
    log(f"  scripts        {SCRIPTS_DIR} ({len(list(SCRIPTS_DIR.glob('*.md')))} found, @name to play)")
    log(f"  responses      {RESPONSES_PATH} (reloaded per request)")
    log(f"  request logs   {LOG_DIR if CONFIG.log_bodies else 'off (FAKE_LOG_BODIES=1 to dump bodies)'}")
    task = asyncio.create_task(report_remaining())
    try:
        yield
    finally:
        task.cancel()
        log("shutting down")


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, bool]:
    return {"ok": True}


@app.get("/events")
async def events(request: Request) -> StreamingResponse:
    """Line-delimited JSON of what the server is doing, for the key driver.

    `tool_use` means the CLI is about to show a permission prompt; `turn_end`
    means the response finished and the next prompt can be typed.
    """
    queue: asyncio.Queue[str] = asyncio.Queue()
    EVENT_SUBSCRIBERS.add(queue)
    log(f"events subscriber connected ({len(EVENT_SUBSCRIBERS)} total)")

    async def pump() -> AsyncIterator[bytes]:
        try:
            yield b'{"event":"hello"}\n'
            while True:
                try:
                    payload = await asyncio.wait_for(queue.get(), timeout=15)
                except asyncio.TimeoutError:
                    # Keepalive doubles as the disconnect check — a dead socket
                    # only surfaces on write.
                    yield b'{"event":"ping"}\n'
                    continue
                yield payload.encode() + b"\n"
        finally:
            EVENT_SUBSCRIBERS.discard(queue)
            log(f"events subscriber gone ({len(EVENT_SUBSCRIBERS)} left)")

    return StreamingResponse(
        pump(), media_type="application/x-ndjson", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
    )


@app.post("/v1/messages/count_tokens")
async def count_tokens(request: Request) -> JSONResponse:
    body = await request.json()
    log_request(request, body, None)
    return JSONResponse({"input_tokens": 1})


@app.post("/v1/messages")
async def messages(request: Request):
    body = await request.json()
    session = session_for(body)
    log_request(request, body, session)

    if body.get("stream"):
        return StreamingResponse(
            stream_messages(request, body, session),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "Connection": "keep-alive"},
        )

    if not is_agent_request(body):
        reply = side_request_reply(body)
        log(f"session={session.id} side request — replying {reply!r}")
        return JSONResponse(
            {
                "id": new_message_id(),
                "type": "message",
                "role": "assistant",
                "model": body.get("model", DEFAULT_MODEL),
                "content": [{"type": "text", "text": reply}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {"input_tokens": 1, "output_tokens": 1},
            }
        )

    message = last_user_text(body)
    rule = pick_rule(load_rules(), message)
    playlist = playlist_for(body, rule, session)
    tool = rule.get("tool_use")
    session.turns += 1

    # Same paced feel on the non-streaming path: wait, then answer in one go.
    delay = CONFIG.think_delay()
    if session.remaining is not None:
        delay = min(delay, session.remaining)
    if delay > 0:
        log(f"session={session.id} thinking for {delay:.1f}s")
        await asyncio.sleep(delay)

    if tool and not playlist.key.startswith("script:") and not has_pending_tool_result(body) and not session.expired:
        content = [
            {
                "type": "tool_use",
                "id": f"toolu_{uuid.uuid4().hex[:20]}",
                "name": tool.get("name", "fake_tool"),
                "input": tool.get("input") or {},
            }
        ]
        stop_reason = "tool_use"
    else:
        # One segment per request here — the transcript advances turn by turn.
        segment = playlist.next()
        log(f"session={session.id} {playlist.label} segment {playlist.position} delivered")
        content = [
            {"type": "thinking", "thinking": segment.thinking, "signature": uuid.uuid4().hex},
            {"type": "text", "text": segment.response},
        ]
        stop_reason = "end_turn"

    return JSONResponse(
        {
            "id": new_message_id(),
            "type": "message",
            "role": "assistant",
            "model": body.get("model", DEFAULT_MODEL),
            "content": content,
            "stop_reason": stop_reason,
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }
    )


def main() -> None:
    # uvicorn installs its own SIGINT/SIGTERM handlers and drains cleanly; this
    # only keeps a stray Ctrl-C from printing a traceback.
    try:
        uvicorn.run(
            app,
            host=CONFIG.host,
            port=CONFIG.port,
            log_level="warning",
            # Without this, Ctrl-C waits forever on open SSE streams.
            timeout_graceful_shutdown=1,
        )
    except KeyboardInterrupt:
        log("interrupted — bye")


if __name__ == "__main__":
    main()
