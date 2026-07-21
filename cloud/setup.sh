#!/usr/bin/env bash
# Provision a fresh Ubuntu box to run fake-claude on a persistent VNC desktop.
#
# Run it on the instance, as the normal login user (not root — the systemd units
# it writes are user units, and it needs $HOME to be yours):
#
#   ./cloud/setup.sh                                        # server runs here too
#   FAKE_CLAUDE_URL=https://x.onrender.com ./cloud/setup.sh  # server is hosted
#
# With FAKE_CLAUDE_URL set, the mock server is somebody else's problem and this
# box only runs the display, the CLI and the driver.
#
# Idempotent: safe to re-run after changing anything. It installs packages,
# creates a VNC password, writes the systemd user units, and enables lingering
# so all of it keeps running when you disconnect.
#
# There is no recorder here on purpose — connect a VNC viewer and record on your
# own machine, which costs nothing and needs no disk on the instance.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

DISPLAY_NUM="${FAKE_DISPLAY:-1}"
VNC_PORT=$(( 5900 + DISPLAY_NUM ))
GEOMETRY="${FAKE_GEOMETRY:-1600x900}"

# Empty means "run the server on this box"; a URL means "it's already running".
REMOTE_URL="${FAKE_CLAUDE_URL:-}"
REMOTE_URL="${REMOTE_URL%/}"

if [ "$(id -u)" = "0" ]; then
  echo "setup.sh: run this as your login user, not root" >&2
  exit 1
fi

echo "==> installing packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  tigervnc-standalone-server tigervnc-common \
  openbox xterm x11-xserver-utils xdotool \
  expect curl git tmux \
  fonts-dejavu-core

# uv is what the project runs everything through; the installer is a no-op if
# it's already there.
if ! command -v uv >/dev/null 2>&1; then
  echo "==> installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

echo "==> syncing python deps"
(cd "$REPO_DIR" && uv sync)
[ -f "$REPO_DIR/.env" ] || cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"

# --- VNC password ------------------------------------------------------------
# The display is bound to localhost only (see the unit below), so this password
# is a second lock behind the SSH tunnel rather than the only one. It still has
# to exist: Xvnc with no auth would accept anyone who reached the port.
if [ ! -f "$HOME/.vnc/passwd" ]; then
  echo "==> creating VNC password"
  mkdir -p "$HOME/.vnc"
  if [ -n "${VNC_PASSWORD:-}" ]; then
    printf '%s\n%s\n\n' "$VNC_PASSWORD" "$VNC_PASSWORD" | vncpasswd "$HOME/.vnc/passwd" >/dev/null
  else
    vncpasswd "$HOME/.vnc/passwd"
  fi
  chmod 600 "$HOME/.vnc/passwd"
fi

mkdir -p "$UNIT_DIR"

# --- units -------------------------------------------------------------------
# Split rather than made into one big unit, because the failure modes are
# genuinely independent: the screen can stay up while you restart the CLI, and
# the CLI can be restarted without dropping your VNC connection.

echo "==> writing systemd user units"

# -localhost is the load-bearing flag: it binds Xvnc to 127.0.0.1 so the only
# way in is an SSH tunnel. Without it the port is world-reachable and the VNC
# password is all that stands between the internet and a live desktop.
cat > "$UNIT_DIR/fake-claude-vnc.service" <<EOF
[Unit]
Description=fake-claude VNC display :$DISPLAY_NUM
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvnc :$DISPLAY_NUM \\
  -geometry $GEOMETRY -depth 24 \\
  -rfbport $VNC_PORT -rfbauth %h/.vnc/passwd \\
  -localhost -SecurityTypes VncAuth -AlwaysShared
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/fake-claude-desktop.service" <<EOF
[Unit]
Description=fake-claude window manager
After=fake-claude-vnc.service
BindsTo=fake-claude-vnc.service

[Service]
Type=simple
Environment=DISPLAY=:$DISPLAY_NUM
# No screensaver, no DPMS: a blanked screen still takes keystrokes but records
# as black, and you would not find out until the run was over.
ExecStartPre=/usr/bin/xset s off -dpms
ExecStart=/usr/bin/openbox
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

if [ -z "$REMOTE_URL" ]; then
  cat > "$UNIT_DIR/fake-claude-server.service" <<EOF
[Unit]
Description=fake-claude mock Anthropic API
After=network.target

[Service]
Type=simple
WorkingDirectory=$REPO_DIR
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.local/bin/uv run mock_server.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
else
  # A stale local server would answer on 127.0.0.1 and quietly win over the
  # hosted one, so remove it rather than leave it lying around disabled.
  systemctl --user disable --now fake-claude-server.service 2>/dev/null || true
  rm -f "$UNIT_DIR/fake-claude-server.service"
fi

# The window title is how keypress-linux.sh finds this terminal, so -title and
# KEYS_WINDOW have to agree.
cat > "$UNIT_DIR/fake-claude-term.service" <<EOF
[Unit]
Description=fake-claude CLI terminal
After=fake-claude-desktop.service fake-claude-server.service
BindsTo=fake-claude-vnc.service

[Service]
Type=simple
WorkingDirectory=$REPO_DIR
Environment=DISPLAY=:$DISPLAY_NUM
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
${REMOTE_URL:+Environment=FAKE_CLAUDE_URL=$REMOTE_URL}
ExecStart=/usr/bin/xterm -title fakeclaude \\
  -fa "DejaVu Sans Mono" -fs 12 -bg black -fg white \\
  -geometry 200x50 \\
  -e $REPO_DIR/fakeclaude
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

echo "==> enabling"
systemctl --user daemon-reload
systemctl --user enable --now fake-claude-vnc.service
systemctl --user enable --now fake-claude-desktop.service
[ -z "$REMOTE_URL" ] && systemctl --user enable --now fake-claude-server.service

# Without lingering, systemd tears down the whole user manager the moment your
# last SSH session closes — which is exactly the thing you are trying to avoid.
sudo loginctl enable-linger "$USER"

if [ -n "$REMOTE_URL" ]; then
  WHERE="$REMOTE_URL (hosted)"
  DRIVER_ENV="FAKE_CLAUDE_URL=$REMOTE_URL "
else
  WHERE="http://127.0.0.1:8787 (this box)"
  DRIVER_ENV=""
fi

cat <<EOF

==> done

  display   :$DISPLAY_NUM  ($GEOMETRY, listening on 127.0.0.1:$VNC_PORT)
  server    $WHERE

Next, from your laptop:

  1. copy credentials so the CLI doesn't show the connectors banner
       scp -r ~/.claude $USER@<host>:~/

  2. tunnel, then point any VNC viewer at localhost:$VNC_PORT
       ssh -L $VNC_PORT:localhost:$VNC_PORT $USER@<host>

  3. back on the box, start the CLI terminal and the driver
       systemctl --user start fake-claude-term
       cd $REPO_DIR && ${DRIVER_ENV}./cloud/keypress-linux.sh --forever

  4. record on your own machine while the viewer is open, then close it.
     The run keeps going without you.
EOF
