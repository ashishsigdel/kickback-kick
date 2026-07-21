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

HOST="${FAKE_HOST:-127.0.0.1}"
PORT="${FAKE_PORT:-8787}"
EVENTS_URL="http://$HOST:$PORT/events"

# Pause before answering a permission prompt — the box needs a moment to render,
# and an instant Enter reads as a machine.
CONFIRM_DELAY="${KEYS_CONFIRM_DELAY:-0.5}"

# Pause after a turn finishes before typing the next prompt — reading time.
READ_SECS="${KEYS_READ_SECS:-3}"

# Per-character typing delay, in milliseconds. A range, not a constant, so the
# cadence stays human. This is the *whole* gap now — see type_text().
TYPE_MIN_MS="${KEYS_TYPE_MIN_MS:-5}"
TYPE_MAX_MS="${KEYS_TYPE_MAX_MS:-14}"

# Pause between one pass over the prompt list and the next, in seconds.
CYCLE_PAUSE="${KEYS_CYCLE_PAUSE_SECS:-2}"

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
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed -e 's/^#//' -e 's/^ //'; exit 0 ;;
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
  )
fi

note() { printf '\n\033[2m--- keys: %s\033[0m\n' "$1"; }

if ! curl -fsS --max-time 2 "http://$HOST:$PORT/health" >/dev/null 2>&1; then
  echo "keypress.sh: no mock server on $HOST:$PORT" >&2
  echo "             start one with:  uv run mock_server.py" >&2
  exit 1
fi

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

# Any osascript failure here is fatal — a half-typed prompt is worse than none.
osa() {
  local err
  if ! err="$(osascript "$@" 2>&1 >/dev/null)"; then
    case "$err" in
      *1002*|*"not allowed to send keystrokes"*) accessibility_help ;;
      *) echo "keypress.sh: osascript failed: $err" >&2 ;;
    esac
    exit 1
  fi
}

press_enter() {
  jiggle_mouse
  osa -e 'tell application "System Events" to key code 36'
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
  local lo hi
  lo="$(awk "BEGIN{printf \"%.4f\", $TYPE_MIN_MS/1000}")"
  hi="$(awk "BEGIN{printf \"%.4f\", $TYPE_MAX_MS/1000}")"
  osa -e "$TYPE_SCRIPT" "$1" "$lo" "$hi"
}

# Fail before the countdown rather than halfway through the first prompt.
# key code 63 is the fn key: it needs the same grant but does nothing.
osa -e 'tell application "System Events" to key code 63'

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
EVENTS_FIFO="$(mktemp -u)"
mkfifo "$EVENTS_FIFO"
curl -fsS -N "$EVENTS_URL" > "$EVENTS_FIFO" &
CURL_PID=$!
trap 'kill "$CURL_PID" 2>/dev/null || true; rm -f "$EVENTS_FIFO"' EXIT
trap 'echo; note "interrupted — stopping"; exit 130' INT TERM

cycle=1
idx=0

send_prompt() {
  local prompt="${PROMPTS[$idx]}"
  note "prompt $((idx + 1))/${#PROMPTS[@]}: $prompt"
  jiggle_mouse
  type_text "$prompt"
  sleep 0.4
  press_enter
}

# Attach to the stream *before* typing anything, so the subscription is live by
# the time the first turn ends — opening the fifo is what lets curl connect.
exec 3<"$EVENTS_FIFO"

# Kick off the first prompt; everything after it is event-driven.
send_prompt

while IFS= read -r line <&3; do
  # Matched on the quoted event name alone, so JSON spacing can't break this.
  case "$line" in
    *'"ping"'*|*'"hello"'*)
      continue ;;
    *'"tool_use"'*)
      note "tool call — permission prompt incoming, Enter in ${CONFIRM_DELAY}s"
      sleep "$CONFIRM_DELAY"
      press_enter
      ;;
    *'"turn_end"'*)
      idx=$(( idx + 1 ))
      if [ "$idx" -ge "${#PROMPTS[@]}" ]; then
        idx=0
        if [ "$CYCLES" != "forever" ] && [ "$cycle" -ge "$CYCLES" ]; then
          note "prompt list done — exiting"
          break
        fi
        cycle=$(( cycle + 1 ))
        note "cycle $cycle — pausing ${CYCLE_PAUSE}s"
        sleep "$CYCLE_PAUSE"
      else
        scroll_mouse
        sleep "$READ_SECS"
      fi
      send_prompt
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
