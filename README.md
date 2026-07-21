# fake-claude

A local mock of the Anthropic Messages API, so you can drive the Claude Code CLI
against canned responses without spending credits.

It speaks enough of the real wire protocol that the CLI can't tell the
difference: proper SSE frame ordering, streamed `text_delta`s, fake `tool_use`
turns with `input_json_delta` chunks, and a clean `end_turn` finish.

## Setup

Everything runs through [uv](https://docs.astral.sh/uv/) — no `pip`, no manual venv.

```bash
uv sync            # installs fastapi, uvicorn, pyyaml, python-dotenv
cp .env.example .env
```

## How to run

Two steps, in two terminals.

**1. Start the mock server:**

```bash
uv run mock_server.py
```

Leave it running. It listens on `http://127.0.0.1:8787`.

**2. Launch Claude Code against it:**

```bash
./fakeclaude                      # interactive
./fakeclaude -p "hello"           # one-shot
```

Every reply now comes from `responses.yaml`. Nothing reaches the real API and
nothing costs credits.

> **Set a finite `FAKE_DURATION` before using `-p`.** With the default
> `FAKE_DURATION=unlimited` the stream never ends, so a one-shot `./fakeclaude -p`
> hangs forever instead of returning. Use `FAKE_DURATION=30s` in `.env` (or
> `FAKE_DURATION=30s uv run mock_server.py`) for non-interactive runs.
> `FAKE_DURATION` is read **once at server startup**, so changing it needs a
> restart — unlike `responses.yaml`, which is reloaded per request.

## How to stop

Go back to the real API in one step: **stop using the wrapper.**

```bash
claude          # real Anthropic API
./fakeclaude    # mock server
```

The two can coexist — `fakeclaude` sets `ANTHROPIC_BASE_URL` and
`ANTHROPIC_MODEL` inline for that single process only. Your shell rc files and
`~/.claude` are never touched, so a plain `claude` is always the real thing.

To shut the mock server down, press `Ctrl-C` in its terminal, or:

```bash
pkill -f mock_server.py
```

Stopping the server is optional for getting back to normal — it only matters if
you want the port back. If the server is down, `./fakeclaude` refuses to launch
with a clear error rather than silently falling through to the real API.

## Running the server

```bash
uv run mock_server.py
```

It listens on `http://127.0.0.1:8787` and prints its resolved config at startup:

```
[08:53:06] fake-claude mock Anthropic API
[08:53:06]   listening      http://127.0.0.1:8787
[08:53:06]   FAKE_DURATION  90s
[08:53:06]   CHUNK_DELAY_MS 40
[08:53:06]   TURN_DELAY_MS  500
[08:53:06]   THINK_DELAY    5-7s (random, before each response)
[08:53:06]   SCRIPT_LOOP    on
[08:53:06]   scripts        /…/fake-claude/scripts (5 found, @name to play)
[08:53:06]   responses      /…/fake-claude/responses.yaml (reloaded per request)
[08:53:06]   request logs   /…/fake-claude/logs
```

### Endpoints

| Endpoint | Behavior |
| --- | --- |
| `POST /v1/messages` | Streaming (`"stream": true`) SSE, or a standard JSON message object |
| `POST /v1/messages/count_tokens` | `{"input_tokens": 1}` |
| `GET /health` | `{"ok": true}` |

Whatever `model` the request sends is echoed back in the response.

The streaming path emits the exact Anthropic event sequence, each frame
formatted as `event: <name>\ndata: <json>\n\n`:

```
message_start → content_block_start → content_block_delta … → content_block_stop
              → message_delta (stop_reason) → message_stop
```

## Launching Claude Code against it

With the server running:

```bash
./fakeclaude              # or: ./fakeclaude "write me a haiku"
```

The script sets `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` **inline for that one
invocation only**. It never writes to your shell rc files or to any global
Claude config — a plain `claude` still hits the real API.

### Looking like a normal session

Two details keep the session from advertising itself as a mock:

**The model reads as Opus 4.8.** `ANTHROPIC_MODEL` is set to `claude-opus-4-8`,
so the header, status line and `/model` all render normally. The server echoes
back whatever model it is sent, so nothing downstream disagrees. Override with
`FAKE_CLAUDE_MODEL` if you want to pose as a different one.

**No auth warning.** Setting `ANTHROPIC_AUTH_TOKEN` makes the CLI print:

```
⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth
  source is set and takes precedence over your claude.ai login
```

which is an obvious tell. The wrapper leaves it unset, so the CLI uses your
normal login and the banner never appears. The mock ignores credentials
entirely.

> Because the token is unset, the CLI sends your real claude.ai credentials to
> `127.0.0.1:8787`. They go nowhere else and the server never logs headers —
> only request bodies land in `logs/`. If you'd rather not send them at all, set
> `FAKE_CLAUDE_TOKEN=dummy` and accept the warning banner. If you aren't logged
> in, that variable is how you supply a token.

## Scripted transcripts (`@1`, `@2`, …)

The main way to drive a realistic session. `scripts/` holds full transcripts —
each an alternating sequence of thinking and replies — and you play one by
@-mentioning it:

```
> @2 review it and tell me what you'd fix first
```

| Script | Topic |
| --- | --- |
| `@1` | Reviewing an auth module — timing-unsafe compare, token expiry, revocation |
| `@2` | Debugging a flaky test — isolating shared fixture state |
| `@3` | Tracking a performance regression — an N+1 introduced by a readable refactor |
| `@4` | Planning a refactor — finding seams, avoiding import cycles |
| `@5` | Implementing a feature — rate limiting, atomicity, verifying the test matters |

`@1`, `@1.md`, and `@scripts/1.md` all resolve to `scripts/1.md`. Anything that
doesn't resolve falls through to `responses.yaml`.

The server plays one segment at a time: **thinking streams for 10–15s, then the
reply it produced arrives** — then the next thinking, the next reply, and so on.
Each reply is its own content block, so they render as separate messages.

### Writing your own

Drop a `.md` file in `scripts/`. Anything before the first marker is a header
comment and is ignored:

```markdown
# Script 6 — migrating the database

[[thinking]]
Before touching the schema I want to know what reads this table...

[[response]]
Checked the callers — 4 modules read `orders.status`...

[[thinking]]
The backfill is the risky part...

[[response]]
Here's the migration, split into two deploys...
```

Files are re-read on every request, so you can edit a transcript while the
server runs. Keep thinking blocks to roughly 40–60 words so they fill the pause
at a natural reading pace.

### Position and looping

The playback position is tracked **per session, per script**, so a follow-up
message continues the transcript instead of restarting it.

When a script runs out and there's still budget left, it loops back to the top
(`SCRIPT_LOOP=true`, the default). Set `SCRIPT_LOOP=false` to end the turn
cleanly once the transcript is done — useful with `FAKE_DURATION=unlimited`,
where it's the only thing that stops the stream.

## Editing responses

`responses.yaml` holds a list of rules. Each has an optional `match` (tried as a
case-insensitive substring first, then as a regex, against the last user
message) and either a `response` string or a `tool_use` block. A rule with no
`match` is the default.

```yaml
rules:
  - match: hello
    response: Hey! Nothing here touched the real API.

  - match: \b(list|show)\b.*\bfiles\b
    tool_use:
      name: Bash
      input:
        command: ls -la

  - response: Default reply when nothing else matches.
```

**The file is re-read on every request** — edit it while the server is running
and the next message picks up your change. No restart.

### Fake tool use

When a matched rule has a `tool_use` block, the server emits a `tool_use`
content block with `input_json_delta` chunks and finishes the turn with
`stop_reason: "tool_use"`. The CLI then executes the tool for real and sends the
result back; the server sees the `tool_result` and answers with text, so the
agent loop keeps turning until the duration budget expires.

## Response pacing

Output is not a firehose. Each response is preceded by a random "thinking"
pause, so a run reads like a real agent working:

```
request → 10-15s thinking → response 1 → 10-15s thinking → response 2 → …
```

The pause length is re-rolled every time from `THINK_MIN_MS`..`THINK_MAX_MS`
(default 10s–15s), so turns never feel metronomic.

**Every gap is a real `thinking` block, not dead air.** The CLI sends
`thinking: {"type": "adaptive"}`, so the server streams actual `thinking_delta`
chunks paced to fill the whole pause. You see the thinking text scroll for the
full 10–15s before each response — including the gaps *between* responses, not
just the first one:

```
thinking… (10-15s) → response 1 → thinking… (10-15s) → response 2 → …
```

Each response is also its own text content block, so they render as separate
messages rather than one ever-growing blob. Server-side it looks like this:

```
[08:10:46] session=35f5624b pre-response thinking for 11.5s
[08:10:58] session=35f5624b response 1 delivered, remaining=32.7s
[08:10:58] session=35f5624b post-response-1 thinking for 13.9s
[08:11:13] session=35f5624b response 2 delivered, remaining=18.0s
```

The thinking prose is generic filler by default. To script it, add a `thinking`
key to any rule in `responses.yaml`:

```yaml
  - match: hello
    thinking: Checking whether this one needs the real API. It does not.
    response: Hey! Nothing here touched the real API.
```

A pause never overruns the budget — it is clamped to whatever time is left, and
the run stops on a response rather than a dangling thought, so it still ends
cleanly on `end_turn`. To go back to continuous streaming:

```dotenv
THINK_MIN_MS=0
THINK_MAX_MS=0
```

This applies to the non-streaming path too: the request simply takes that long
before returning its one JSON message.

## Duration control (`.env`)

`FAKE_DURATION` controls how long a single fake agentic run keeps producing
output before ending cleanly. It accepts `30s`, `5m`, `1h`, a bare number of
seconds (`90`), or `unlimited`.

The budget is tracked **per agentic session, not per HTTP request**, so a
multi-turn tool loop stays inside the same budget.

### Finite

```dotenv
FAKE_DURATION=30s
```

The server keeps streaming — cycling through the canned response text and
issuing fake `tool_use` turns where rules define them — until the deadline
passes. It then finishes the current pass and emits a proper
`content_block_stop` → `message_delta` (`stop_reason: end_turn`) →
`message_stop`, so the CLI sees a clean finish rather than a dropped
connection. Remaining time is logged periodically:

```
[09:45:59] POST /v1/messages model=claude-opus-4-8 stream=True session=0e8417a8-7f1 remaining=25.0s msg='@5 build it'
[06:21:34] session=53482f60dc53 still streaming, remaining=0.0s
[06:21:35] session=53482f60dc53 turn=1 finished stop_reason=end_turn
```

### Unlimited

```dotenv
FAKE_DURATION=unlimited
```

The fake agentic loop never self-terminates — it keeps cycling until you kill
the server or quit the CLI. Client disconnects and `Ctrl-C` are both handled
without tracebacks:

```
[07:39:13] stream cancelled (session=a8bef500e681)
[07:39:34] shutting down
```

### Other settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `FAKE_DURATION` | `unlimited` | Run budget: `30s`, `5m`, `1h`, `90`, `unlimited` |
| `CHUNK_DELAY_MS` | `40` | Delay between streamed text deltas |
| `TURN_DELAY_MS` | `500` | Pause between simulated agentic turns |
| `THINK_MIN_MS` | `5000` | Shortest random "thinking" pause before a response |
| `THINK_MAX_MS` | `7000` | Longest random "thinking" pause before a response |
| `SCRIPT_LOOP` | `true` | Restart a script from the top when it runs out |
| `HOST` | `127.0.0.1` | Bind address |
| `PORT` | `8787` | Bind port |

## Hands-off driving (`drive.sh`)

`./drive.sh` runs the whole session with nobody at the keyboard. It launches
`./fakeclaude` on a real pty, types each prompt one character at a time, presses
Enter to send it, waits out the reply, and presses Enter again whenever a
permission box appears. Everything happens locally in a real terminal — you just
watch it go.

```bash
./drive.sh                              # built-in prompt list, one pass
./drive.sh '@1 review it' '@2 why?'     # these prompts instead
./drive.sh -f prompts.txt               # one per line, # comments ignored
./drive.sh --forever                    # cycle until you stop it
./drive.sh --cycles 5                   # five passes over the list
```

The default list opens with a plain `list the files in this directory`, which
trips the tool-use rule in `responses.yaml` so you can watch the driver answer a
permission prompt, then plays `@1` through `@5` in order.

A turn is considered finished once the CLI has been silent for `DRIVE_IDLE_SECS`
(default `4`) — comfortably longer than the server's ~0.8s worst-case gap between
chunks. Ctrl-C stops the driver and the CLI with it.

| Variable | Default | Meaning |
| --- | --- | --- |
| `DRIVE_IDLE_SECS` | `4` | Silence that marks the end of a turn |
| `DRIVE_READ_SECS` | `3` | Pause after a reply before typing the next prompt |
| `DRIVE_TYPE_MIN_MS` | `35` | Fastest per-character typing delay |
| `DRIVE_TYPE_MAX_MS` | `110` | Slowest per-character typing delay |
| `DRIVE_CYCLES` | `1` | Passes over the prompt list (`forever` to keep going) |
| `DRIVE_CYCLE_PAUSE_SECS` | `30` | Pause between one pass and the next |
| `DRIVE_CAFFEINATE` | `1` | Set to `0` to let the machine sleep normally |

### Staying awake

The driver re-executes itself under `caffeinate -dimsu`, which holds four power
assertions — display sleep, idle sleep, disk sleep, system sleep — plus a
"user is active" declaration, for as long as the run lasts. Because `caffeinate`
is launched with the driver *as its utility*, macOS releases every assertion the
instant the driver exits. No power settings are changed and nothing survives the
run; `pmset -g assertions` shows them appear and disappear with it.

Each cycle is a fresh CLI session, so one wedged TUI costs a single pass instead
of the whole run, and the server hands out new script cursors so transcripts
restart from the top. Ctrl-C stops everything, caffeinate included.

Requires `expect`, which ships with macOS. Set `SCRIPT_LOOP=false` before an
unattended run — with looping on, a transcript never ends and the driver waits
on it forever.

## Running it in the cloud

[`AWS.md`](AWS.md) covers the split deployment: the mock server free on Render,
the CLI and driver on a small EC2 box with a persistent VNC desktop that keeps
running after you disconnect. `render.yaml` is the Render blueprint,
`cloud/setup.sh` provisions the Ubuntu instance, and `cloud/keypress-linux.sh`
is the `xdotool` port of `keypress.sh` for X.

`FAKE_CLAUDE_URL` is what makes the split work — every script takes a full base
URL and defaults to `http://127.0.0.1:8787`, so the same commands run locally or
against a hosted server.

## Logging

Every request prints one readable line to stdout — method, path, model, last
user message, stream flag, session id, and time remaining. Full request bodies
are dumped to `logs/` as timestamped JSON for inspection.

## Getting back to normal

Nothing here is sticky. Kill the server (`Ctrl-C`), or just run `claude` instead
of `./fakeclaude` — with the env vars unset, the CLI goes straight back to the
real Anthropic API. No global config or shell rc file was ever touched.
