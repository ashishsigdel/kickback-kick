#!/usr/bin/env bash
# Type into a Claude Code session running in another window on an X display,
# driven by what the mock server is doing. The Linux port of ../keypress.sh.
#
# Same three parts, all on the cloud box now:
#   1)  uv run mock_server.py     (systemd: fake-claude-server)
#   2)  ./keypress-linux.sh       <- this script
#   3)  ./fakeclaude              <- the CLI, in a terminal on $DISPLAY
#
# The driver never reads the CLI's output — it can't, it isn't its parent. It
# subscribes to the server's /events stream instead, because the server is the
# thing that decides when a tool call goes out and when a turn ends:
#
#   tool_use  -> a permission prompt is about to appear -> wait, press Enter
#   turn_end  -> the response finished                  -> wait, type the next prompt
#
# Events are delivered live, so anything published while the stream was down is
# gone for good. That makes a missed turn_end indistinguishable from a turn that
# never ended, which is why nothing here blocks forever: KEYS_STALL_SECS bounds
# how long the driver waits before assuming it missed one and moving on.
#
# Keys are real X input events via xdotool's XTEST calls, one character at a
# time with a jittered gap, so it looks like someone typing. They go to whatever
# window has focus on $DISPLAY, which is why this activates the target window
# once at startup and why nothing else should steal focus mid-run.
#
#   ./keypress-linux.sh                          # play the built-in prompt list
#   ./keypress-linux.sh '@1 review it' '@2 why?' # play these prompts instead
#   ./keypress-linux.sh -f prompts.txt           # one prompt per line, # comments ignored
#   ./keypress-linux.sh --forever                # keep cycling until stopped
#
# There is no caffeinate here and none is needed — a VNC display has no idle
# sleep. What it does have is an X screensaver that blanks the screen and would
# ruin a recording, so the guard below turns that off instead.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$BASE_DIR/.." && pwd)"

# Read the same .env the server reads, so every knob in the project lives in one
# file. Only KEY=VALUE lines with a shell-safe name are taken and the value is
# never evaluated — this file is data, not a script to source. Anything already
# in the environment wins, so `KEYS_READ_MAX_SECS=20 ./keypress-linux.sh` still
# overrides the file for one run.
load_env_file() {
  local file="$1" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      [A-Za-z_]*=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%$'\r'}"
    # Strip one layer of matching quotes; unquoted values keep any inline #.
    case "$value" in
      \"*\") value="${value%\"}"; value="${value#\"}" ;;
      \'*\') value="${value%\'}"; value="${value#\'}" ;;
    esac
    [ -n "${!key+set}" ] && continue
    export "$key=$value"
  done < "$file"
}
load_env_file "$REPO_DIR/.env"

# Which display the CLI's terminal lives on. Everything here is display-scoped;
# get this wrong and xdotool types into a different desktop, or none at all.
export DISPLAY="${DISPLAY:-:1}"

# The server is hosted, so that is the default. FAKE_CLAUDE_URL is a full base
# URL so it can name an https host — assembling one from host+port can only ever
# produce http, which a hosted server won't answer on. FAKE_HOST/FAKE_PORT still
# select a local server, but only when set explicitly.
DEFAULT_URL="https://kickback-kick.onrender.com"
if [ -n "${FAKE_CLAUDE_URL:-}" ]; then
  BASE_URL="$FAKE_CLAUDE_URL"
elif [ -n "${FAKE_HOST:-}" ] || [ -n "${FAKE_PORT:-}" ]; then
  BASE_URL="http://${FAKE_HOST:-127.0.0.1}:${FAKE_PORT:-8787}"
else
  BASE_URL="$DEFAULT_URL"
fi
BASE_URL="${BASE_URL%/}"
EVENTS_URL="$BASE_URL/events"

# Window to type into, matched against the title. The CLI's terminal is usually
# the only window on the display, but being explicit means a stray dialog can't
# silently eat a prompt.
WINDOW_NAME="${KEYS_WINDOW:-fakeclaude}"

# Pause before answering a permission prompt — the box needs a moment to render,
# and an instant Enter reads as a machine.
CONFIRM_DELAY="${KEYS_CONFIRM_DELAY:-0.5}"

# How many times to press Enter at a permission prompt, and the gap between
# presses. One shot works for a short one-liner (rg, git log) but a long or
# multi-line command (a piped jq filter, a quoted grep, a YAML block scalar)
# takes longer to render into the box, especially over VNC on a remote box —
# a single blind Enter can land before the dialog has focus, or get dropped
# entirely. Repeating is safe: extra Enters against a plain shell prompt are
# no-ops (blank lines), so there's no harm in a few redundant presses.
CONFIRM_RETRIES="${KEYS_CONFIRM_RETRIES:-3}"
CONFIRM_RETRY_GAP="${KEYS_CONFIRM_RETRY_GAP:-1}"

# Pause after a turn finishes before typing the next prompt — reading time. A
# range in seconds; a fresh value is drawn every time. Set both to the same
# number for a constant.
READ_MIN_SECS="${KEYS_READ_MIN_SECS:-${KEYS_READ_SECS:-3}}"
READ_MAX_SECS="${KEYS_READ_MAX_SECS:-${KEYS_READ_SECS:-8}}"

# Pause between finishing the typing of a prompt and pressing Enter — the beat
# where a person re-reads what they just wrote. Range in seconds.
ENTER_MIN_SECS="${KEYS_ENTER_MIN_SECS:-0.4}"
ENTER_MAX_SECS="${KEYS_ENTER_MAX_SECS:-2.5}"

# Per-character typing delay, in milliseconds. A range, not a constant, so the
# cadence stays human. See type_text() for why this is a shell loop.
TYPE_MIN_MS="${KEYS_TYPE_MIN_MS:-30}"
TYPE_MAX_MS="${KEYS_TYPE_MAX_MS:-190}"

# Multiplier applied to that whole range once per prompt, so prompts differ from
# each other and not just character to character. 0.7 is a brisk one, 1.4 a
# distracted one. Both ends 1 turns it off.
TYPE_SPEED_MIN="${KEYS_TYPE_SPEED_MIN:-0.7}"
TYPE_SPEED_MAX="${KEYS_TYPE_SPEED_MAX:-1.4}"

# Hesitation at word and clause boundaries: the chance (0-1) that a space or
# punctuation mark is followed by a longer pause instead of the usual gap, and
# how long that pause runs in seconds. This is where composing the next phrase
# shows up on a recording. Chance 0 turns it off.
PAUSE_CHANCE="${KEYS_PAUSE_CHANCE:-0.12}"
PAUSE_MIN_SECS="${KEYS_PAUSE_MIN_SECS:-0.3}"
PAUSE_MAX_SECS="${KEYS_PAUSE_MAX_SECS:-1.4}"

# Pause between one pass over the prompt list and the next, in seconds. Range,
# drawn fresh at the end of every cycle.
CYCLE_PAUSE_MIN_SECS="${KEYS_CYCLE_PAUSE_MIN_SECS:-${KEYS_CYCLE_PAUSE_SECS:-2}}"
CYCLE_PAUSE_MAX_SECS="${KEYS_CYCLE_PAUSE_MAX_SECS:-${KEYS_CYCLE_PAUSE_SECS:-15}}"

# How long to sit with no tool_use and no turn_end before deciding the turn was
# missed and moving on anyway. This is what keeps an unattended run alive: every
# event is delivered live to whoever is subscribed at that instant, so anything
# published while the stream was down is simply gone, and without a deadline the
# driver waits for it forever. A run that stops three hours in looks exactly
# like a run that finished.
#
# The floor is set by the longest legitimate silence, which is a tool call: the
# CLI gives a command up to 120s before it times out, and the server thinks for
# another 5-7s after the result comes back. 240 clears that with room to spare.
STALL_SECS="${KEYS_STALL_SECS:-240}"

# How often the read loop wakes up to check that deadline.
POLL_SECS="${KEYS_POLL_SECS:-5}"

# Clear the CLI's conversation every N prompts; 0 never clears. The CLI resends
# the entire transcript on every request, so an uncleared run grows without
# bound — bodies were over a megabyte by the end of a long session, and every
# turn re-uploads and re-parses all of it. Clearing periodically keeps requests
# small, and reads on a recording as moving on to a fresh task.
CLEAR_EVERY="${KEYS_CLEAR_EVERY:-10}"

# Small mouse moves/scrolls around typing and Enter, purely cosmetic — a cursor
# that never twitches while text appears is the one thing that reads as fake on
# a recording. xdotool already handles the keystrokes, so no new dependency.
MOUSE_ACTIVITY="${KEYS_MOUSE_ACTIVITY:-1}"

PROMPT_FILE=""
CYCLES="${KEYS_CYCLES:-1}"
declare -a PROMPTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file) PROMPT_FILE="${2:?-f needs a path}"; shift 2 ;;
    --forever) CYCLES="forever"; shift ;;
    -n|--cycles) CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed -e 's/^#//' -e 's/^ //'; exit 0 ;;
    *) PROMPTS+=("$1"); shift ;;
  esac
done

if [ -n "$PROMPT_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    PROMPTS+=("$line")
  done < "$PROMPT_FILE"
fi

if [ ${#PROMPTS[@]} -eq 0 ]; then
  PROMPTS=(
    "@1 take a look at this auth module and tell me what you find"
    "@2 this test fails about one run in twenty, can you dig in?"
    "@3 the /search endpoint went from 80ms to 1.2s after friday's deploy"
    "@4 how would you break this module up?"
    "@5 add rate limiting to the API"
    "@6 the orders list gets slower the more orders we have"
    "@7 the worker's memory climbs all day until it gets OOM killed"
    "@8 this module has no tests at all, can you add some?"
    "@9 CI passes on every PR but fails on main, any idea why?"
    "@10 review this API design before we ship it"
    "@11 we're seeing duplicate charges from the payment webhook, can you dig in?"
    "@12 can you review this search filter endpoint for injection risk?"
    "@13 the worker pool deadlocks under load, can you find out why?"
    "@14 review this PR adding a caching layer to our hottest endpoint"
    "@15 we need to change a column type on a huge table without downtime, how would you do it?"
    "@16 memory spiked right after today's deploy, can you take a look?"
    "@17 our pagination cursor sometimes skips or repeats rows, can you find the bug?"
    "@18 review this token-bucket rate limiter before we ship it"
    "@19 we're getting intermittent 502s behind the load balancer, can you dig in?"
    "@20 this class has become a god object, how would you break it up?"
    "@21 a customer got double-charged, can you make this payment endpoint idempotent?"
    "@22 this pod keeps getting OOMKilled, can you find out why?"
    "@23 review this diff switching money math from floats to fixed-point"
    "@24 CI has gotten really slow lately, can you investigate?"
    "@25 two workers are somehow holding the same distributed lock at once, can you dig in?"
    "@26 some websocket clients think they're still connected when they're not, can you look into it?"
    "@27 this migration locks the accounts table, can you review it before we run it?"
    "@28 events are processing out of order across regions, can you dig in?"
    "@29 the React app's heap keeps growing on every navigation, can you find the leak?"
    "@30 this GraphQL resolver is firing one query per row, can you fix it?"
    "@31 the nightly ETL is silently corrupting some rows, can you dig in?"
    "@32 our retry loop is hammering our own downstream service, can you take a look?"
    "@33 review this new gRPC service before it joins the mesh"
    "@34 we're getting a cache stampede on the storefront's hottest key, can you fix it?"
    "@35 every rolling deploy causes a spike in errors, can you find out why?"
    "@36 review our bcrypt-to-argon2 migration before we ship it"
    "@37 the CSV export is turning names into mojibake, can you fix it?"
    "@38 this Jest test only fails in CI, can you dig in?"
    "@39 review the feature-flagged checkout redesign before we roll it out"
    "@40 I think our webhook signature check isn't actually verifying anything, can you look?"
    "@41 the nightly cron job is firing twice, can you find out why?"
    "@42 review this proposed index strategy for the slow report page"
    "@43 this GraphQL query is slow, can you dig into it?"
    "@44 pagination is silently dropping the last row on every page, can you find the bug?"
    "@45 review this refactor that batches the calls"
    "@46 the process is running out of file descriptors, can you find the leak?"
    "@47 we get a thundering herd every time this cache key expires, can you fix it?"
    "@48 review this Redis rate limiter before it goes into the gateway"
    "@49 the ledger is off by a few cents here and there, can you dig into the rounding?"
    "@50 the queue consumer just stops processing sometimes without crashing, can you dig in?"
    "@51 review this async/await refactor, I'm worried it's swallowing errors"
    "@52 logs are missing for the exact window of last night's incident, can you dig in?"
    "@53 CORS is blocking a legitimate frontend origin, can you fix it?"
    "@54 review this new Postgres connection pool setup"
    "@55 we've got a segfault somewhere in a native extension, can you track it down?"
    "@56 the Docker build in CI has gotten really slow, can you speed it up?"
    "@57 review this diff adding distributed tracing spans"
    "@58 our timezone conversion silently drops a DST transition, can you find the bug?"
    "@59 this e2e test only fails in CI, can you dig in?"
    "@60 review this diff switching the job queue from FIFO to priority-based"
    "@61 an unbounded queue is causing OOMs under burst traffic, can you fix it?"
    "@62 expired JWTs are somehow still being accepted, can you dig in?"
    "@63 review this diff adding a circuit breaker around a flaky downstream call"
    "@64 we're processing some events twice, can you find out why?"
    "@65 the feature flag rollout caused a spike in client errors, can you dig in?"
    "@66 review this diff migrating an internal API from REST to gRPC"
    "@67 we're getting synchronized retry storms, can you look into the backoff logic?"
    "@68 the connection pool exhausts under load, can you find the leak?"
    "@69 startup got a lot slower after the last dependency bump, can you dig in?"
    "@70 review this diff adding read replicas and routing reads to them"
    "@71 the fuzzy search ranker is returning pretty irrelevant results, can you dig in?"
    "@72 the import job reports SUCCESS but nothing actually got imported, can you find out why?"
    "@73 can you check the internal invoices API for IDOR issues?"
    "@74 review the soft-delete rollout, I'm worried some query paths still return deleted rows"
    "@75 a bulk insert failed partway through and left partial writes, can you dig in?"
    "@76 cache miss rate keeps climbing under memory pressure, can you look into it?"
    "@77 we got a 4xx spike right after the mobile client update, can you dig in?"
    "@78 review the row-level security rollout before we turn it on for all tenants"
    "@79 optimistic locking is silently dropping concurrent updates, can you dig in?"
    "@80 metrics went dark for one service after a recent change, can you find out why?"
    "@81 full-text search on the articles table has gotten really slow, can you dig in?"
    "@82 review this dead-letter queue diff, want to make sure poison messages don't loop forever"
    "@83 large file uploads are coming out corrupted, can you dig into the chunked upload logic?"
    "@84 a retry loop that never backs off is burning through our rate limit, can you fix it?"
    "@85 this migration ended up locking the orders table in prod, can you dig into what happened?"
    "@86 review this diff adding HMAC request signing"
    "@87 date-range filtering breaks around timezone boundaries, can you find the bug?"
    "@88 we're serving stale cache data seconds after a confirmed write, can you dig in?"
    "@89 can you check whether the multi-tenant API is leaking data across accounts?"
    "@90 review this refactor moving a slow endpoint onto Celery background tasks"
    "@91 I think this sort comparator violates transitivity, can you check?"
    "@92 the HPA isn't scaling up despite high CPU, can you dig in?"
    "@93 we're getting intermittent connection reset by peer between two gRPC services, can you dig in?"
    "@94 review this diff adding Zod validation to the public API"
    "@95 this state machine allows an invalid transition under a race, can you find it?"
    "@96 the Spark batch job produces different output between reruns, can you dig in?"
    "@97 our p50 latency looks fine but p99 is terrible, can you dig in?"
    "@98 review this diff adding a Bloom filter in front of a DB existence check"
    "@99 our retry logic is double-charging customers on transient errors, can you fix it?"
    "@100 a three-way merge is corrupting files under a specific edit pattern, can you dig in?"
  )
fi

note() { printf '\n\033[2m--- keys: %s\033[0m\n' "$1"; }

command -v xdotool >/dev/null 2>&1 || {
  echo "keypress-linux.sh: 'xdotool' not found — sudo apt install -y xdotool" >&2
  exit 127
}

if ! xdotool getdisplaygeometry >/dev/null 2>&1; then
  echo "keypress-linux.sh: no X display at DISPLAY=$DISPLAY" >&2
  echo "                   start one with:  systemctl --user start fake-claude-vnc" >&2
  exit 1
fi

# A sleeping free-tier host answers nothing for the first ~50s, so treat silence
# as "not awake yet" before treating it as "not there".
#
# Pulled out into a function, not just inline at startup, because the events
# reconnect loop below calls it too: a dropped stream and a Render free-tier
# restart look the same from here, and blindly retrying curl every 2s against a
# host that's still waking up just produces a wall of connection errors instead
# of actually waiting the cold start out.
#
# Returns non-zero rather than exiting when the deadline passes — the caller
# decides. At startup a dead server is fatal; mid-run it is not, and this used
# to `exit 1` from inside the reconnect subshell, which killed the writer end of
# the events fifo and ended the whole run. A Render cold start can take longer
# than WAKE_SECS on its own, so that was a routine outage turning into a
# permanent stop.
WAKE_SECS="${FAKE_CLAUDE_WAKE_SECS:-90}"
wait_for_health() {
  curl -fsS --max-time 5 "$BASE_URL/health" >/dev/null 2>&1 && return 0
  printf 'keypress-linux.sh: waking %s (up to %ss)' "$BASE_URL" "$WAKE_SECS" >&2
  local deadline=$(( SECONDS + WAKE_SECS ))
  until curl -fsS --max-time 10 "$BASE_URL/health" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf '\n' >&2
      echo "keypress-linux.sh: no mock server at $BASE_URL" >&2
      echo "                   local:  uv run mock_server.py" >&2
      echo "                   hosted: check the service is live in Render" >&2
      return 1
    fi
    printf '.' >&2
    sleep 2
  done
  printf ' up\n' >&2
}

wait_for_health || exit 1

# /events is what drives this script. A server started before it existed answers
# 404 — a restart is the fix, and it's worth saying so plainly.
#
# The stream never ends, so curl always exits non-zero here (28, timed out).
# That's expected: -w has already reported the status by then, and a real
# connection failure reports 000 instead. Never `|| echo` onto this — it
# concatenates with what -w printed.
code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "$EVENTS_URL" 2>/dev/null)" || true
code="${code:-000}"
if [ "$code" != "200" ]; then
  echo "keypress-linux.sh: $EVENTS_URL returned $code, expected 200" >&2
  if [ "$code" = "404" ]; then
    echo "                   that server predates the /events endpoint — restart it:" >&2
    echo "                     systemctl --user restart fake-claude-server" >&2
  fi
  exit 1
fi

# Stop the X screensaver and DPMS blanking. A blanked display would keep
# accepting keystrokes just fine, but the recording would be twenty minutes of
# black, and that failure only shows up after the run.
if command -v xset >/dev/null 2>&1; then
  xset s off -dpms 2>/dev/null || true
fi

# --- key delivery ------------------------------------------------------------
# xdotool sends XTEST events to whatever window holds focus, so the target has
# to be focused and stay focused.
#
# The obvious alternative — `xdotool type --window <id>` — looks like it removes
# that constraint, but it delivers XSendEvent instead of XTEST, and terminals
# ignore synthetic events by default (xterm needs allowSendEvents, most others
# have no opt-in at all). Prompts would silently vanish. So: activate once, send
# real events after.
#
# Nothing in here is fatal on its own. Every xdotool call is one round trip to
# an X server that a reconnecting VNC client can disturb, and under `set -e` a
# single transient failure would end an otherwise healthy run — the same class
# of silent stop this script exists to avoid. A dropped keystroke costs one
# prompt; the stall watchdog picks the run back up.
focus_target() {
  local id
  id="$(xdotool search --onlyvisible --name "$WINDOW_NAME" 2>/dev/null | head -n1)" || true
  if [ -z "$id" ]; then
    echo "keypress-linux.sh: no visible window matching '$WINDOW_NAME' on $DISPLAY" >&2
    echo "                   set KEYS_WINDOW to match your terminal's title" >&2
    return 1
  fi
  xdotool windowactivate --sync "$id" 2>/dev/null || xdotool windowfocus "$id" 2>/dev/null || true
  WINDOW_ID="$id"
}

# A random number of seconds between two bounds, two decimals. $RANDOM rather
# than awk's rand(): awk seeded from the clock returns the same value for calls
# inside the same second, which is exactly how these are used (type, pause,
# type again) and would quietly make every draw in a burst identical.
rand_secs() {
  awk -v lo="$1" -v hi="$2" -v r="$RANDOM" \
    'BEGIN { if (hi < lo) hi = lo; printf "%.2f", lo + (hi - lo) * (r / 32767) }'
}

press_enter() {
  jiggle_mouse
  xdotool key --clearmodifiers Return 2>/dev/null || true
}

# Small relative move, a few px in any direction — enough to register as
# activity on screen without the cursor visibly jumping around. Moving the
# mouse doesn't steal focus under openbox's click-to-focus, so this is safe
# to fire mid-run.
jiggle_mouse() {
  [ "$MOUSE_ACTIVITY" = "1" ] || return 0
  local dx dy
  dx=$(( (RANDOM % 17) - 8 ))
  dy=$(( (RANDOM % 17) - 8 ))
  xdotool mousemove_relative -- "$dx" "$dy" 2>/dev/null || true
}

# A couple of wheel notches, as if glancing back up the transcript while
# waiting on a reply. Button 4/5 are the scroll-up/scroll-down XTEST buttons.
scroll_mouse() {
  [ "$MOUSE_ACTIVITY" = "1" ] || return 0
  local n
  n=$(( (RANDOM % 3) + 1 ))
  xdotool click --repeat "$n" 5 2>/dev/null || true
}

# One xdotool process per character, unlike the macOS version which pushes the
# loop into AppleScript. That was needed there because an osascript spawn is
# ~40ms and would have swamped a 5-14ms gap; an xdotool spawn is a couple of
# milliseconds, so the straightforward loop is close enough to the requested
# cadence and much easier to follow.
#
# Chaining it into a single call is not the fix it appears to be: xdotool's
# `type` consumes every remaining argument as more text, so a trailing `sleep`
# in the same command gets typed out literally instead of run.
#
# Two things here are not just jitter. Uniform noise around a fixed mean is not
# what typing looks like: over a 60-character prompt the per-character draws
# average out, so every prompt lands at exactly the same words-per-minute even
# though no two keystrokes match. Real typing varies *between* prompts as much
# as within them, and it stalls at word and clause boundaries where the next
# phrase gets composed. So the range is scaled by a per-prompt speed factor, and
# the loop rolls for a longer pause after the characters people pause after.
type_text() {
  local text="$1" i ch ms secs lo_ms hi_ms
  # One speed factor for the whole prompt — this one typed briskly, the next
  # while half-attending to something else. Without it the law of large numbers
  # flattens every prompt to the same average rate. Rounded to whole
  # milliseconds here so the per-character loop stays integer arithmetic and
  # never has to spawn awk.
  read -r lo_ms hi_ms <<EOF
$(awk -v lo="$TYPE_MIN_MS" -v hi="$TYPE_MAX_MS" \
      -v fl="$TYPE_SPEED_MIN" -v fh="$TYPE_SPEED_MAX" -v r="$RANDOM" \
      'BEGIN { f = fl + (fh - fl) * (r / 32767); printf "%d %d", lo * f, hi * f }')
EOF
  [ "$hi_ms" -gt "$lo_ms" ] || hi_ms=$(( lo_ms + 1 ))
  # Integer percentages, so the per-character roll below is a shell comparison
  # rather than an awk call per keystroke.
  local pause_pct pause_lo_ms pause_hi_ms
  pause_pct="$(awk -v c="$PAUSE_CHANCE" 'BEGIN { printf "%d", c * 100 }')"
  pause_lo_ms="$(awk -v s="$PAUSE_MIN_SECS" 'BEGIN { printf "%d", s * 1000 }')"
  pause_hi_ms="$(awk -v s="$PAUSE_MAX_SECS" 'BEGIN { printf "%d", s * 1000 }')"
  [ "$pause_hi_ms" -gt "$pause_lo_ms" ] || pause_hi_ms=$(( pause_lo_ms + 1 ))

  for (( i = 0; i < ${#text}; i++ )); do
    ch="${text:i:1}"
    # --clearmodifiers so a stuck Shift from an earlier key can't uppercase the
    # run, and -- so a leading '-' in a prompt isn't read as an option.
    xdotool type --clearmodifiers --delay 0 -- "$ch" 2>/dev/null || true
    case "$ch" in
      ' '|','|'.'|';'|':'|'!'|'?')
        if [ $(( RANDOM % 100 )) -lt "$pause_pct" ]; then
          ms=$(( RANDOM % (pause_hi_ms - pause_lo_ms + 1) + pause_lo_ms ))
        else
          ms=$(( RANDOM % (hi_ms - lo_ms + 1) + lo_ms ))
        fi ;;
      *) ms=$(( RANDOM % (hi_ms - lo_ms + 1) + lo_ms )) ;;
    esac
    # Milliseconds to a decimal `sleep` argument without shelling out to awk
    # once per character. The awk form this replaces also tripped a bash 3.2
    # parser bug with escaped quotes inside a command substitution, which made
    # the script silently untestable on a Mac.
    printf -v secs '%d.%03d' $(( ms / 1000 )) $(( ms % 1000 ))
    sleep "$secs"
  done
}

focus_target || exit 1
note "typing into window $WINDOW_ID ('$WINDOW_NAME') on $DISPLAY"
[ "$MOUSE_ACTIVITY" = "1" ] && note "mouse activity on" || note "mouse activity off (KEYS_MOUSE_ACTIVITY=0)"
note "starting in 5s"
sleep 5

# --- event loop --------------------------------------------------------------
# One long-lived connection for the whole run. The turn index lives here: each
# turn_end advances to the next prompt, each tool_use just answers the box.
EVENTS_FIFO=""
SSE_PID=""

stop_events() {
  exec 3<&- 2>/dev/null || true
  if [ -n "$SSE_PID" ]; then
    pkill -P "$SSE_PID" 2>/dev/null || true
    kill "$SSE_PID" 2>/dev/null || true
  fi
  [ -n "$EVENTS_FIFO" ] && rm -f "$EVENTS_FIFO"
  SSE_PID=""
}

# Reconnect rather than exit. Over localhost the stream only ends when the
# server does. Across the internet it also ends on a dropped connection or a
# free-tier host restarting, and a run that silently stops three hours in looks
# exactly like a run that finished.
#
# wait_for_health runs before each reconnect attempt so a Render free-tier
# restart turns into one visible wait instead of a curl failure every 2s. Its
# return value is deliberately ignored: however long the server stays down, this
# loop keeps trying. stderr is dropped on the curl call itself — the printf
# below is the one message this produces, instead of raw "curl: (56) Recv
# failure" noise. The `|| true` matters under set -e: without it, curl's exit
# status on the very first drop would kill this subshell for good instead of
# looping.
#
# The gap is not free: events emitted while disconnected are gone, and a missed
# turn_end leaves the driver waiting for something that already happened. That
# is what the stall watchdog in the read loop is for.
start_events() {
  EVENTS_FIFO="$(mktemp -u)"
  mkfifo "$EVENTS_FIFO"
  (
    while true; do
      curl -fsS -N "$EVENTS_URL" 2>/dev/null || true
      printf '\n\033[2m--- keys: events stream dropped — reconnecting\033[0m\n' >&2
      sleep 2
      wait_for_health || true
    done
  ) > "$EVENTS_FIFO" &
  SSE_PID=$!
  # Opening the read end is what lets the subshell's curl connect.
  exec 3<"$EVENTS_FIFO"
}

trap 'stop_events' EXIT
trap 'echo; note "interrupted — stopping"; exit 130' INT TERM

cycle=1
idx=0
sent=0        # prompts typed so far, for the /clear cadence
awaiting=0    # $SECONDS when the driver last had something to wait for

# /clear is handled entirely inside the CLI: it sends no request, so no turn_end
# follows it. It has to happen inline here, never as a state the read loop then
# waits on.
clear_context() {
  note "clearing the CLI conversation (every ${CLEAR_EVERY} prompts)"
  type_text "/clear"
  sleep "$(rand_secs "$ENTER_MIN_SECS" "$ENTER_MAX_SECS")"
  press_enter
  sleep 1.5
}

send_prompt() {
  local prompt="${PROMPTS[$idx]}"
  # Re-assert focus every prompt. Over a long unattended run a window manager
  # hint or a reconnecting VNC client can move it, and a prompt typed into the
  # void is indistinguishable from a hung server until much later.
  focus_target || note "window '$WINDOW_NAME' not found — typing at whatever has focus"
  if [ "$CLEAR_EVERY" -gt 0 ] && [ "$sent" -gt 0 ] && [ $(( sent % CLEAR_EVERY )) -eq 0 ]; then
    clear_context
  fi
  note "prompt $((idx + 1))/${#PROMPTS[@]}: $prompt"
  jiggle_mouse
  type_text "$prompt"
  sleep "$(rand_secs "$ENTER_MIN_SECS" "$ENTER_MAX_SECS")"
  press_enter
  sent=$(( sent + 1 ))
  awaiting=$SECONDS
}

# Move to the next prompt and type it. Returns 1 when the run is over, which is
# the only way out of the read loop. Shared by the turn_end branch and the stall
# watchdog so a recovered turn advances exactly like a real one.
advance_and_send() {
  idx=$(( idx + 1 ))
  if [ "$idx" -ge "${#PROMPTS[@]}" ]; then
    idx=0
    if [ "$CYCLES" != "forever" ] && [ "$cycle" -ge "$CYCLES" ]; then
      note "prompt list done — exiting"
      return 1
    fi
    cycle=$(( cycle + 1 ))
    local pause
    pause="$(rand_secs "$CYCLE_PAUSE_MIN_SECS" "$CYCLE_PAUSE_MAX_SECS")"
    note "cycle $cycle — pausing ${pause}s"
    sleep "$pause"
  else
    scroll_mouse
    local read_pause
    read_pause="$(rand_secs "$READ_MIN_SECS" "$READ_MAX_SECS")"
    note "reading for ${read_pause}s before the next prompt"
    sleep "$read_pause"
  fi
  send_prompt
}

# Attach to the stream *before* typing anything, so the subscription is live by
# the time the first turn ends.
start_events

# Kick off the first prompt; everything after it is event-driven.
send_prompt

while true; do
  # A timed read, not a blocking one. Nothing else in this loop can notice that
  # an event went missing, and every way that happens — a dropped stream, a
  # server restart, a permission prompt that never got its Enter — otherwise
  # ends as a driver sitting silently forever next to an idle CLI.
  if IFS= read -t "$POLL_SECS" -r line <&3; then
    :
  elif kill -0 "$SSE_PID" 2>/dev/null; then
    # Timed out with nothing to read. That is normal — the server only speaks at
    # tool_use and turn_end, and pings in between — so only act on a silence
    # long enough that no legitimate turn could still be running.
    #
    # The liveness check is how timeout is told apart from end-of-stream: bash
    # 3.2 (still what macOS ships) returns 1 for both, so read's status can't
    # distinguish them. A fifo with a live writer cannot be at EOF, so if the
    # subshell is still there, this was a timeout.
    if [ $(( SECONDS - awaiting )) -ge "$STALL_SECS" ]; then
      note "no events for ${STALL_SECS}s — assuming the turn was missed, moving on"
      advance_and_send || break
    fi
    continue
  else
    # EOF: the writer subshell died. It is built never to, so this is a kill
    # from outside; rebuild it rather than letting the run end here.
    note "events reader hit EOF — restarting the subscription"
    stop_events
    sleep 2
    wait_for_health || true
    start_events
    awaiting=$SECONDS
    continue
  fi

  # Matched on the quoted event name alone, so JSON spacing can't break this.
  case "$line" in
    *'"ping"'*|*'"hello"'*)
      # Deliberately does not reset the stall clock: a ping proves the stream is
      # up, not that the turn is progressing.
      continue ;;
    *'"tool_use"'*)
      note "tool call — permission prompt incoming, Enter in ${CONFIRM_DELAY}s (x${CONFIRM_RETRIES})"
      awaiting=$SECONDS
      sleep "$CONFIRM_DELAY"
      for (( i = 0; i < CONFIRM_RETRIES; i++ )); do
        press_enter
        # An `&&` here would leave the loop at status 1 on its last pass, which
        # under set -e takes the whole script down with it.
        if [ "$i" -lt "$(( CONFIRM_RETRIES - 1 ))" ]; then
          sleep "$CONFIRM_RETRY_GAP"
        fi
      done
      ;;
    # turn_abort is the server saying a turn ended without finishing — the CLI
    # hung up mid-stream, or the request was cancelled. Same handling: there is
    # nothing more coming for this prompt, so move to the next one.
    *'"turn_end"'*|*'"turn_abort"'*)
      advance_and_send || break
      ;;
    '')
      continue ;;
    *)
      # Never fail silently here: an unmatched line means the driver would sit
      # forever waiting for an event that already went past it.
      note "unrecognised event, ignoring: $line"
      ;;
  esac
done
