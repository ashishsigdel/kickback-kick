#!/usr/bin/env bash
# Drive the Claude Code CLI against the mock server with no human at the keyboard.
#
# Launches ./fakeclaude on a real pty, types prompts character by character,
# presses Enter to send them, and answers permission prompts by pressing Enter
# again. Everything runs locally, in a real terminal, exactly as if someone were
# sitting there doing it — you just watch.
#
#   ./drive.sh                          # play the built-in prompt list
#   ./drive.sh '@1 review it' '@2 why?' # play these prompts instead
#   ./drive.sh -f prompts.txt           # one prompt per line, # comments ignored
#   ./drive.sh --forever                # keep cycling until stopped
#   ./drive.sh --cycles 5               # five passes over the list
#
# The run holds the machine awake with caffeinate for its own lifetime; the
# assertion is released the moment the driver exits. DRIVE_CAFFEINATE=0 opts out.
# Ctrl-C stops the driver and the CLI with it.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$BASE_DIR/fakeclaude"

# Keep the machine awake for as long as the driver runs. caffeinate holds its
# assertions for the lifetime of the utility it launches, so re-executing
# ourselves under it means the guard is released the moment the driver exits —
# nothing lingers, and no system settings are changed.
#   -d display  -i idle sleep  -m disk  -s system (on AC)  -u user active
if [ "${DRIVE_CAFFEINATE:-1}" != "0" ] && [ -z "${DRIVE_CAFFEINATED:-}" ] \
   && command -v caffeinate >/dev/null 2>&1; then
  export DRIVE_CAFFEINATED=1
  exec caffeinate -dimsu "${BASH_SOURCE[0]}" ${@+"$@"}
fi

# How long the CLI must produce no output before the driver calls the turn
# finished and types the next prompt. The server's slowest gap between chunks
# is ~0.8s, so a few seconds is plenty without being sluggish.
IDLE_SECS="${DRIVE_IDLE_SECS:-4}"

# Per-character typing delay, in milliseconds. A range, not a constant, so the
# typing has a human cadence instead of a machine-gun one.
TYPE_MIN_MS="${DRIVE_TYPE_MIN_MS:-35}"
TYPE_MAX_MS="${DRIVE_TYPE_MAX_MS:-110}"

# Pause after a turn finishes before typing the next prompt — reading time.
READ_SECS="${DRIVE_READ_SECS:-3}"

# Pause between one pass over the prompt list and the next, in seconds.
CYCLE_PAUSE="${DRIVE_CYCLE_PAUSE_SECS:-30}"

PROMPT_FILE=""
CYCLES="${DRIVE_CYCLES:-1}"
declare -a PROMPTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file) PROMPT_FILE="${2:?-f needs a path}"; shift 2 ;;
    --forever) CYCLES="forever"; shift ;;
    -n|--cycles) CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed -e 's/^#//' -e 's/^ //'; exit 0 ;;
    *) PROMPTS+=("$1"); shift ;;
  esac
done

if [ -n "$PROMPT_FILE" ]; then
  while IFS= read -r line; do
    [ -z "${line// }" ] && continue
    [ "${line:0:1}" = "#" ] && continue
    PROMPTS+=("$line")
  done < "$PROMPT_FILE"
fi

# Default run: one plain prompt that trips a tool-use permission box (so you can
# see the driver answer it), then the scripted transcripts in order.
if [ ${#PROMPTS[@]} -eq 0 ]; then
  PROMPTS=(
    "list the files in this directory"
    "@1 review it and tell me what you'd fix first"
    "@2 what's actually making it flaky?"
    "@3 where did the regression come from?"
    "@4 plan the refactor before touching anything"
    "@5 go ahead and implement it"
  )
fi

command -v expect >/dev/null 2>&1 || { echo "drive.sh: 'expect' not found on PATH." >&2; exit 127; }
[ -x "$LAUNCHER" ] || { echo "drive.sh: $LAUNCHER not found or not executable." >&2; exit 1; }

BASE_URL="${FAKE_CLAUDE_URL:-http://127.0.0.1:8787}"
if ! curl -fsS --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; then
  echo "drive.sh: no mock server at $BASE_URL" >&2
  echo "          start one with:  uv run mock_server.py" >&2
  exit 1
fi

# Hand the spawned pty the same geometry as this terminal, or the TUI wraps at
# expect's default 80x24 and the pane text becomes unreadable.
SIZE="$(stty size 2>/dev/null || echo '40 120')"
ROWS="${SIZE% *}"
COLS="${SIZE#* }"

if [ "$CYCLES" != "forever" ]; then
  case "$CYCLES" in
    ''|*[!0-9]*) echo "drive.sh: --cycles wants a number or --forever, got '$CYCLES'" >&2; exit 2 ;;
  esac
fi

echo "drive.sh: ${#PROMPTS[@]} prompts, idle=${IDLE_SECS}s, typing=${TYPE_MIN_MS}-${TYPE_MAX_MS}ms/char"
echo "drive.sh: cycles=$CYCLES, pause between cycles=${CYCLE_PAUSE}s"
[ -n "${DRIVE_CAFFEINATED:-}" ] && echo "drive.sh: caffeinate holding display/system awake for this run"
echo "drive.sh: driving $LAUNCHER — hands off the keyboard, Ctrl-C to stop"
echo

EXP_FILE="$(mktemp -t drive)"
trap 'rm -f "$EXP_FILE"' EXIT
trap 'echo; echo "drive.sh: interrupted — stopping"; exit 130' INT TERM

cat > "$EXP_FILE" <<'EXPECT'
set rows      [lindex $argv 0]
set cols      [lindex $argv 1]
set idle      [lindex $argv 2]
set type_min  [lindex $argv 3]
set type_max  [lindex $argv 4]
set read_secs [lindex $argv 5]
set launcher  [lindex $argv 6]
set prompts   [lrange $argv 7 end]

# The CLI redraws constantly, so nothing is ever matched on a single chunk.
# Instead every chunk is appended to a rolling window that gets scanned for the
# permission box; idleness is what marks the end of a turn.
set window ""
set WINDOW_MAX 6000

# Anything the CLI puts on screen when it wants a keypress before continuing.
# Enter takes the highlighted option, which is always the affirmative one.
set CONFIRM_RE {(?i)(do you want to|do you trust the files|proceed\?|\(y/n\))}

# A box that redraws its question after being answered would otherwise have the
# driver hammering Enter forever. Stop confirming past this many in one turn.
set MAX_CONFIRMS 8

proc note {msg} {
    send_user "\n\033\[2m--- drive: $msg\033\[0m\n"
}

# Type like a person: one character at a time, with a jittered gap.
proc human_type {text} {
    global type_min type_max
    foreach ch [split $text ""] {
        send -- $ch
        after [expr {$type_min + int(rand() * ($type_max - $type_min))}]
    }
}

# Consume output until the CLI has been silent for `secs`, answering any
# permission box that shows up along the way. Returns the number of confirms.
proc settle {secs} {
    global window WINDOW_MAX CONFIRM_RE MAX_CONFIRMS
    set timeout $secs
    set confirms 0
    set capped 0
    while {1} {
        expect {
            -re {.+} {
                append window $expect_out(buffer)
                if {[string length $window] > $WINDOW_MAX} {
                    set window [string range $window end-$WINDOW_MAX end]
                }
                # Escape sequences split words apart; strip them before matching.
                regsub -all {\x1b\[[0-9;?]*[a-zA-Z]} $window "" clean
                if {[regexp $CONFIRM_RE $clean]} {
                    if {$confirms >= $MAX_CONFIRMS} {
                        if {!$capped} {
                            note "$MAX_CONFIRMS confirms this turn — not pressing Enter again"
                            set capped 1
                        }
                        set window ""
                    } else {
                        after 500
                        note "permission prompt — pressing Enter"
                        send -- "\r"
                        incr confirms
                        set window ""
                        after 500
                    }
                }
            }
            timeout { return $confirms }
            eof     { return $confirms }
        }
    }
}

set rc 0
if {[catch {
    spawn -noecho $launcher
    catch {exec stty rows $rows columns $cols < $spawn_out(slave,name)}

    # Startup: banner, trust dialog, whatever else — let it all land first.
    note "waiting for the CLI to come up"
    settle $idle

    set n 0
    foreach prompt $prompts {
        incr n
        note "prompt $n/[llength $prompts]"
        set window ""
        human_type $prompt
        after 400
        send -- "\r"

        # The whole transcript arrives as one streamed response, so a single
        # settle covers the turn; confirms are handled inside it.
        settle $idle
        if {$n < [llength $prompts]} { after [expr {$read_secs * 1000}] }
    }

    note "prompts done — exiting the CLI"
    set window ""
    human_type "/exit"
    after 300
    send -- "\r"
    settle 3
    catch {send -- "\003"}
    catch {wait}
} err]} {
    send_user "\ndrive: $err\n"
    set rc 1
}
exit $rc
EXPECT

# Each cycle is a fresh CLI session, so a crash or a wedged TUI costs one pass
# rather than the whole run — and the mock server hands out new script cursors,
# so transcripts start from the top again.
cycle=0
while :; do
  cycle=$((cycle + 1))
  if [ "$CYCLES" != "forever" ] && [ "$cycle" -gt "$CYCLES" ]; then
    break
  fi
  if [ "$CYCLES" = "forever" ]; then
    echo "drive.sh: cycle $cycle"
  else
    echo "drive.sh: cycle $cycle/$CYCLES"
  fi

  if ! expect -f "$EXP_FILE" \
       "$ROWS" "$COLS" "$IDLE_SECS" "$TYPE_MIN_MS" "$TYPE_MAX_MS" "$READ_SECS" \
       "$LAUNCHER" "${PROMPTS[@]}"; then
    echo "drive.sh: cycle $cycle ended badly — carrying on" >&2
  fi

  if [ "$CYCLES" != "forever" ] && [ "$cycle" -ge "$CYCLES" ]; then
    break
  fi
  sleep "$CYCLE_PAUSE"
done

echo "drive.sh: done"
