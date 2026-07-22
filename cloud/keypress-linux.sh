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

# Which display the CLI's terminal lives on. Everything here is display-scoped;
# get this wrong and xdotool types into a different desktop, or none at all.
export DISPLAY="${DISPLAY:-:1}"

# The server may not be on this machine. FAKE_CLAUDE_URL is a full base URL so
# it can name an https host — assembling one from host+port the way the macOS
# script does can only ever produce http, which a hosted server won't answer on.
# FAKE_HOST/FAKE_PORT still work for a local server.
BASE_URL="${FAKE_CLAUDE_URL:-http://${FAKE_HOST:-127.0.0.1}:${FAKE_PORT:-8787}}"
BASE_URL="${BASE_URL%/}"
EVENTS_URL="$BASE_URL/events"

# Window to type into, matched against the title. The CLI's terminal is usually
# the only window on the display, but being explicit means a stray dialog can't
# silently eat a prompt.
WINDOW_NAME="${KEYS_WINDOW:-fakeclaude}"

# Pause before answering a permission prompt — the box needs a moment to render,
# and an instant Enter reads as a machine.
CONFIRM_DELAY="${KEYS_CONFIRM_DELAY:-0.5}"

# Pause after a turn finishes before typing the next prompt — reading time.
READ_SECS="${KEYS_READ_SECS:-3}"

# Per-character typing delay, in milliseconds. A range, not a constant, so the
# cadence stays human. See type_text() for why this is a shell loop.
TYPE_MIN_MS="${KEYS_TYPE_MIN_MS:-5}"
TYPE_MAX_MS="${KEYS_TYPE_MAX_MS:-14}"

# Pause between one pass over the prompt list and the next, in seconds.
CYCLE_PAUSE="${KEYS_CYCLE_PAUSE_SECS:-2}"

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
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed -e 's/^#//' -e 's/^ //'; exit 0 ;;
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
WAKE_SECS="${FAKE_CLAUDE_WAKE_SECS:-90}"
wait_for_health() {
  curl -fsS --max-time 5 "$BASE_URL/health" >/dev/null 2>&1 && return 0
  printf 'keypress-linux.sh: waking %s (up to %ss)' "$BASE_URL" "$WAKE_SECS" >&2
  deadline=$(( SECONDS + WAKE_SECS ))
  until curl -fsS --max-time 10 "$BASE_URL/health" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf '\n' >&2
      echo "keypress-linux.sh: no mock server at $BASE_URL" >&2
      echo "                   local:  uv run mock_server.py" >&2
      echo "                   hosted: check the service is live in Render" >&2
      exit 1
    fi
    printf '.' >&2
    sleep 2
  done
  printf ' up\n' >&2
}

wait_for_health

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
focus_target() {
  local id
  id="$(xdotool search --onlyvisible --name "$WINDOW_NAME" 2>/dev/null | head -n1)" || true
  if [ -z "$id" ]; then
    echo "keypress-linux.sh: no visible window matching '$WINDOW_NAME' on $DISPLAY" >&2
    echo "                   set KEYS_WINDOW to match your terminal's title" >&2
    exit 1
  fi
  xdotool windowactivate --sync "$id" 2>/dev/null || xdotool windowfocus "$id"
  WINDOW_ID="$id"
}

press_enter() {
  jiggle_mouse
  xdotool key --clearmodifiers Return
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
type_text() {
  local text="$1" i ch ms
  for (( i = 0; i < ${#text}; i++ )); do
    ch="${text:i:1}"
    # --clearmodifiers so a stuck Shift from an earlier key can't uppercase the
    # run, and -- so a leading '-' in a prompt isn't read as an option.
    xdotool type --clearmodifiers --delay 0 -- "$ch"
    ms=$(( RANDOM % (TYPE_MAX_MS - TYPE_MIN_MS + 1) + TYPE_MIN_MS ))
    sleep "$(awk "BEGIN{printf \"%.4f\", $ms/1000}")"
  done
}

focus_target
note "typing into window $WINDOW_ID ('$WINDOW_NAME') on $DISPLAY"
[ "$MOUSE_ACTIVITY" = "1" ] && note "mouse activity on" || note "mouse activity off (KEYS_MOUSE_ACTIVITY=0)"
note "starting in 5s"
sleep 5

# --- event loop --------------------------------------------------------------
# One long-lived connection for the whole run. The turn index lives here: each
# turn_end advances to the next prompt, each tool_use just answers the box.
EVENTS_FIFO="$(mktemp -u)"
mkfifo "$EVENTS_FIFO"

# Reconnect rather than exit. Over localhost the stream only ends when the
# server does, so the macOS script can let curl's exit end the run. Across the
# internet it also ends on a dropped connection or a free-tier host restarting,
# and a run that silently stops three hours in looks exactly like a run that
# finished.
#
# wait_for_health runs before each reconnect attempt so a Render free-tier
# restart turns into one visible wait instead of a curl failure every 2s.
# stderr is dropped on the curl call itself — the printf below is the one
# message this produces, instead of raw "curl: (56) Recv failure" noise. The
# `|| true` matters under set -e: without it, curl's exit status on the very
# first drop would kill this subshell for good instead of looping.
#
# The gap is not free: events emitted while disconnected are gone, and a missed
# turn_end leaves the driver waiting for something that already happened. If a
# run stalls with the CLI plainly idle, that's this — Ctrl-C and restart.
(
  while true; do
    curl -fsS -N "$EVENTS_URL" 2>/dev/null || true
    printf '\n\033[2m--- keys: events stream dropped — reconnecting\033[0m\n' >&2
    sleep 2
    wait_for_health
  done
) > "$EVENTS_FIFO" &
SSE_PID=$!
trap 'pkill -P "$SSE_PID" 2>/dev/null || true; kill "$SSE_PID" 2>/dev/null || true; rm -f "$EVENTS_FIFO"' EXIT
trap 'echo; note "interrupted — stopping"; exit 130' INT TERM

cycle=1
idx=0

send_prompt() {
  local prompt="${PROMPTS[$idx]}"
  note "prompt $((idx + 1))/${#PROMPTS[@]}: $prompt"
  # Re-assert focus every prompt. Over a long unattended run a window manager
  # hint or a reconnecting VNC client can move it, and a prompt typed into the
  # void is indistinguishable from a hung server until much later.
  xdotool windowactivate --sync "$WINDOW_ID" 2>/dev/null || true
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
