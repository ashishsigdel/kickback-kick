#!/usr/bin/env bash
# Type into a Claude Code session running in *another* terminal, driven by what
# the mock server is doing.
#
# Three terminals:
#   1)  uv run mock_server.py
#   2)  ./keypress.sh            <- this script
#   3)  ./fakeclaude             <- the CLI, must stay the frontmost window
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
# Keys are real OS-level key events via System Events, one character at a time
# with a jittered gap, so it looks like someone typing. They go to whatever app
# is frontmost, so leave terminal 3 focused and don't click away mid-run.
#
#   ./keypress.sh                          # play the built-in prompt list
#   ./keypress.sh '@1 review it' '@2 why?' # play these prompts instead
#   ./keypress.sh -f prompts.txt           # one prompt per line, # comments ignored
#   ./keypress.sh --forever                # keep cycling until stopped
#
# The run holds the machine awake with caffeinate for its own lifetime; the
# assertion is released the moment the driver exits. KEYS_CAFFEINATE=0 opts out.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the machine and the display awake for as long as the driver runs.
# caffeinate holds its assertions for the lifetime of the utility it launches,
# so re-executing ourselves under it means the guard is released when we exit —
# nothing lingers, and no system settings are changed.
#   -d display  -i idle sleep  -m disk  -s system (on AC)  -u user active
if [ "${KEYS_CAFFEINATE:-1}" != "0" ] && [ -z "${KEYS_CAFFEINATED:-}" ] \
   && command -v caffeinate >/dev/null 2>&1; then
  export KEYS_CAFFEINATED=1
  exec caffeinate -dimsu "${BASH_SOURCE[0]}" ${@+"$@"}
fi

# The server is hosted now, so the default is the Render URL rather than
# localhost — a bare ./keypress.sh needs no env vars at all.
#
# Same var fakeclaude uses, so pointing both scripts somewhere else is one env
# var instead of two. FAKE_HOST/FAKE_PORT still select a local server, but only
# when set explicitly: defaulting them here would send every run to 127.0.0.1
# again. Note they can only ever build an http:// URL, which is why the hosted
# default is a full base URL.
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

# A free-tier Render service sleeps after ~15 minutes idle and needs the better
# part of a minute to wake — a 2s check would always report "no server" on the
# first run of the day. Same wait fakeclaude does.
WAKE_SECS="${FAKE_CLAUDE_WAKE_SECS:-90}"

# Pause before answering a permission prompt — the box needs a moment to render,
# and an instant Enter reads as a machine.
CONFIRM_DELAY="${KEYS_CONFIRM_DELAY:-0.5}"

# How many times to press Enter at a permission prompt, and the gap between
# presses. One shot works for a short one-liner (rg, git log) but a long or
# multi-line command (a piped jq filter, a quoted grep, a YAML block scalar)
# takes longer to render into the box — a single blind Enter can land before
# the dialog has focus, or get dropped entirely. Repeating is safe: extra
# Enters against a plain shell prompt are no-ops (blank lines).
CONFIRM_RETRIES="${KEYS_CONFIRM_RETRIES:-3}"
CONFIRM_RETRY_GAP="${KEYS_CONFIRM_RETRY_GAP:-1}"

# Pause after a turn finishes before typing the next prompt — reading time.
READ_SECS="${KEYS_READ_SECS:-3}"

# Per-character typing delay, in milliseconds. A range, not a constant, so the
# cadence stays human. This is the *whole* gap now — see type_text().
TYPE_MIN_MS="${KEYS_TYPE_MIN_MS:-5}"
TYPE_MAX_MS="${KEYS_TYPE_MAX_MS:-14}"

# Pause between one pass over the prompt list and the next, in seconds.
CYCLE_PAUSE="${KEYS_CYCLE_PAUSE_SECS:-2}"

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
# a recording. Needs cliclick (`brew install cliclick`); silently skipped
# without it, since it's decoration, not something the script depends on.
MOUSE_ACTIVITY="${KEYS_MOUSE_ACTIVITY:-1}"
CLICLICK="$(command -v cliclick || true)"
[ -n "$CLICLICK" ] || MOUSE_ACTIVITY=0

PROMPT_FILE=""
CYCLES="${KEYS_CYCLES:-1}"
declare -a PROMPTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file) PROMPT_FILE="${2:?-f needs a path}"; shift 2 ;;
    --forever) CYCLES="forever"; shift ;;
    -n|--cycles) CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed -e 's/^#//' -e 's/^ //'; exit 0 ;;
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

# Blocks until $BASE_URL/health answers, waiting out a Render free-tier cold
# start if needed. Used at startup, and again if the events stream drops and
# it turns out the server itself went away rather than just the connection.
#
# Returns non-zero rather than exiting when the deadline passes — the caller
# decides. At startup a dead server is fatal; mid-run it is not, and a Render
# cold start can take longer than WAKE_SECS on its own, which used to turn a
# routine outage into a run that ended for good.
wait_for_health() {
  curl -fsS --max-time 5 "$BASE_URL/health" >/dev/null 2>&1 && return 0
  printf 'keypress.sh: waking %s (up to %ss)' "$BASE_URL" "$WAKE_SECS" >&2
  local deadline=$(( SECONDS + WAKE_SECS ))
  until curl -fsS --max-time 10 "$BASE_URL/health" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf '\n' >&2
      echo "keypress.sh: no mock server at $BASE_URL" >&2
      echo "             local:  uv run mock_server.py" >&2
      echo "             hosted: check the service is live in the Render dashboard" >&2
      return 1
    fi
    printf '.' >&2
    sleep 2
  done
  printf '\n' >&2
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
  echo "keypress.sh: $EVENTS_URL returned $code, expected 200" >&2
  if [ "$code" = "404" ]; then
    echo "             that server predates the /events endpoint — restart it:" >&2
    echo "               Ctrl-C in the server terminal, then  uv run mock_server.py" >&2
  fi
  exit 1
fi

# --- key delivery ------------------------------------------------------------
# System Events sends to the frontmost app, so terminal 3 has to stay focused.
# Sending keystrokes needs an Accessibility grant for the app running *this*
# script; without it every call fails with error 1002.
TERM_APP="${TERM_PROGRAM:-your terminal app}"

accessibility_help() {
  cat >&2 <<EOF

keypress.sh: macOS is blocking synthetic keystrokes (osascript error 1002).

  Grant Accessibility to $TERM_APP:
    System Settings > Privacy & Security > Accessibility
    enable $TERM_APP (add it with + if it isn't listed)

  Then quit $TERM_APP completely (Cmd-Q, not just the window) and reopen it —
  the permission is only picked up by a fresh process.

  Opening that pane now...
EOF
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
}

# Reports the failure and returns non-zero; only the startup probe below treats
# that as fatal. A missing Accessibility grant is worth stopping for — nothing
# will ever be typed — but a one-off osascript error mid-run is not: under
# `set -e` an `exit` here would end an otherwise healthy unattended run over a
# single dropped keystroke, which the stall watchdog would have recovered from.
osa() {
  local err
  if ! err="$(osascript "$@" 2>&1 >/dev/null)"; then
    case "$err" in
      *1002*|*"not allowed to send keystrokes"*) accessibility_help ;;
      *) echo "keypress.sh: osascript failed: $err" >&2 ;;
    esac
    return 1
  fi
}

press_enter() {
  jiggle_mouse
  osa -e 'tell application "System Events" to key code 36' || true
}

# Small relative move, a few px in any direction — enough to register as
# activity on screen without the cursor visibly jumping around.
jiggle_mouse() {
  [ "$MOUSE_ACTIVITY" = "1" ] || return 0
  local dx dy
  dx=$(( (RANDOM % 17) - 8 ))
  dy=$(( (RANDOM % 17) - 8 ))
  "$CLICLICK" "m:+${dx},+${dy}" >/dev/null 2>&1 || true
}

# A couple of wheel notches, as if glancing back up the transcript while
# waiting on a reply.
scroll_mouse() {
  [ "$MOUSE_ACTIVITY" = "1" ] || return 0
  local amt
  amt=$(( (RANDOM % 3) + 1 ))
  "$CLICLICK" "w:0,-${amt}" >/dev/null 2>&1 || true
}

# The per-character loop lives in AppleScript, not here. One osascript process
# per prompt instead of one per character: process spawn is ~40ms, which used
# to dominate the delay and put a floor under how fast typing could go.
# Text and timings arrive as arguments, so there's no quoting to escape.
TYPE_SCRIPT='on run argv
	set t to item 1 of argv
	set lo to (item 2 of argv) as real
	set hi to (item 3 of argv) as real
	tell application "System Events"
		repeat with i from 1 to (count of characters of t)
			keystroke (character i of t)
			delay (random number from lo to hi)
		end repeat
	end tell
end run'

type_text() {
  # Milliseconds to the decimal seconds AppleScript's `delay` wants. Built with
  # printf rather than awk: the `"$(awk "… \"%.4f\" …")"` form this replaces is
  # mis-parsed by bash 3.2 — still what /bin/bash is on macOS — which dropped
  # the format string and left `delay` with an empty argument.
  local lo hi
  printf -v lo '%d.%03d' $(( TYPE_MIN_MS / 1000 )) $(( TYPE_MIN_MS % 1000 ))
  printf -v hi '%d.%03d' $(( TYPE_MAX_MS / 1000 )) $(( TYPE_MAX_MS % 1000 ))
  osa -e "$TYPE_SCRIPT" "$1" "$lo" "$hi" || true
}

# Fail before the countdown rather than halfway through the first prompt.
# key code 63 is the fn key: it needs the same grant but does nothing.
osa -e 'tell application "System Events" to key code 63' || exit 1

note "keystrokes allowed — $TERM_APP has Accessibility"
if [ "$MOUSE_ACTIVITY" = "1" ]; then
  note "mouse activity on — cliclick found at $CLICLICK"
else
  note "mouse activity off — install with 'brew install cliclick' to enable"
fi
note "focus the Claude Code terminal now — starting in 5s"
sleep 5

# --- event loop --------------------------------------------------------------
# One long-lived connection for the whole run. The turn index lives here: each
# turn_end advances to the next prompt, each tool_use just answers the box.
#
# connect_events opens a fresh fifo/curl/fd 3 each call, so a dropped
# connection (Render free-tier reset, network blip) can be re-established
# without losing idx/cycle — see the reconnect branch in the read loop below.
connect_events() {
  EVENTS_FIFO="$(mktemp -u)"
  mkfifo "$EVENTS_FIFO"
  curl -fsS -N "$EVENTS_URL" > "$EVENTS_FIFO" 2>/dev/null &
  CURL_PID=$!
  exec 3<"$EVENTS_FIFO"
}

disconnect_events() {
  exec 3<&- 2>/dev/null || true
  kill "$CURL_PID" 2>/dev/null || true
  rm -f "$EVENTS_FIFO"
}

# Attach to the stream *before* typing anything, so the subscription is live by
# the time the first turn ends — opening the fifo is what lets curl connect.
connect_events
trap 'disconnect_events' EXIT
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
  sleep 0.4
  press_enter
  sleep 1.5
}

send_prompt() {
  local prompt="${PROMPTS[$idx]}"
  if [ "$CLEAR_EVERY" -gt 0 ] && [ "$sent" -gt 0 ] && [ $(( sent % CLEAR_EVERY )) -eq 0 ]; then
    clear_context
  fi
  note "prompt $((idx + 1))/${#PROMPTS[@]}: $prompt"
  jiggle_mouse
  type_text "$prompt"
  sleep 0.4
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
    note "cycle $cycle — pausing ${CYCLE_PAUSE}s"
    sleep "$CYCLE_PAUSE"
  else
    scroll_mouse
    sleep "$READ_SECS"
  fi
  send_prompt
}

# Kick off the first prompt; everything after it is event-driven.
send_prompt

while true; do
  # A timed read, not a blocking one. Nothing else in this loop can notice that
  # an event went missing, and every way that happens — a dropped stream, a
  # server restart, a permission prompt that never got its Enter — otherwise
  # ends as a driver sitting silently forever next to an idle CLI.
  if IFS= read -t "$POLL_SECS" -r line <&3; then
    :
  elif kill -0 "$CURL_PID" 2>/dev/null; then
    # Timed out with nothing to read. That is normal — the server only speaks at
    # tool_use and turn_end, and pings in between — so only act on a silence
    # long enough that no legitimate turn could still be running.
    #
    # The liveness check is how timeout is told apart from end-of-stream: bash
    # 3.2, which is what macOS ships, returns 1 for both, so read's status can't
    # distinguish them. A fifo with a live writer cannot be at EOF, so if curl
    # is still there, this was a timeout.
    if [ $(( SECONDS - awaiting )) -ge "$STALL_SECS" ]; then
      note "no events for ${STALL_SECS}s — assuming the turn was missed, moving on"
      advance_and_send || break
    fi
    continue
  else
    # curl exited — the connection reset from under us (Render free-tier and
    # similar hosts do this on long-lived streams). Reconnect instead of
    # letting the whole run die silently. wait_for_health absorbs a server
    # restart; however long it stays down, this keeps waiting rather than
    # ending the run.
    note "events stream dropped — reconnecting"
    disconnect_events
    sleep 2
    wait_for_health || true
    connect_events
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
