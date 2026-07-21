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

# The folder VS Code opens. Anything with code in it works — this is only ever
# scenery, since the CLI's replies are canned and never touch these files.
PROJECT_DIR="${FAKE_PROJECT_DIR:-$HOME/project}"

if [ "$(id -u)" = "0" ]; then
  echo "setup.sh: run this as your login user, not root" >&2
  exit 1
fi

# --- swap --------------------------------------------------------------------
# A 2 GB instance runs this comfortably in steady state but has almost no
# headroom for the spikes — VS Code starting up, an apt upgrade — and the OOM
# killer takes the largest process, which is exactly the one you are filming.
# Swap is the difference between a brief stall and a dead session.
if [ "${FAKE_SWAP:-1}" != "0" ] && [ ! -f /swapfile ]; then
  echo "==> adding 2G swap"
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  # Default swappiness of 60 pages out an idle GUI aggressively, which shows up
  # as a stutter the moment you interact with it again. Lower means swap stays
  # an emergency reserve rather than routine.
  sudo sysctl -q vm.swappiness=10
  grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf >/dev/null
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

# The native installer puts claude in ~/.local/bin and keeps itself updated.
# Deliberately not npm: that path needs Node 22+ on the box for no benefit here,
# since the package just downloads the same binary anyway.
if ! command -v claude >/dev/null 2>&1; then
  echo "==> installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash
fi

# --- VS Code (optional) ------------------------------------------------------
# FAKE_VSCODE=0 skips it and leaves you with the plain xterm session.
if [ "${FAKE_VSCODE:-1}" != "0" ] && ! command -v code >/dev/null 2>&1; then
  echo "==> installing VS Code"
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor | sudo tee /etc/apt/keyrings/packages.microsoft.gpg >/dev/null
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq code
fi

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

# --- VS Code workspace -------------------------------------------------------
# The point of VS Code here is that the session looks like someone working, so
# it needs a project open and a terminal already running the CLI. A folderOpen
# task does both without anyone touching the keyboard.
if [ "${FAKE_VSCODE:-1}" != "0" ]; then
  echo "==> configuring VS Code workspace"
  mkdir -p "$PROJECT_DIR/.vscode" "$HOME/.config/Code/User"

  # focus:true is what makes the auto-driver work: it leaves keyboard focus in
  # the integrated terminal, so xdotool's keystrokes land in the CLI rather than
  # in an editor pane.
  cat > "$PROJECT_DIR/.vscode/tasks.json" <<EOF
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "claude",
      "type": "shell",
      "command": "$REPO_DIR/fakeclaude",
      "runOptions": { "runOn": "folderOpen" },
      "presentation": {
        "reveal": "always",
        "panel": "dedicated",
        "focus": true,
        "clear": true
      },
      "problemMatcher": []
    }
  ]
}
EOF

  # Without allowAutomaticTasks VS Code shows a "this folder has tasks, allow?"
  # prompt on every open and the task never runs unattended.
  cat > "$HOME/.config/Code/User/settings.json" <<'EOF'
{
  "task.allowAutomaticTasks": "on",
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.startupEditor": "none",
  "terminal.integrated.fontSize": 13,
  "editor.fontSize": 13,
  "window.commandCenter": false,
  "update.mode": "none",
  "telemetry.telemetryLevel": "off"
}
EOF
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

if [ "${FAKE_VSCODE:-1}" != "0" ]; then
  # --new-window so a re-start doesn't just raise an existing window without
  # re-running the folderOpen task; --disable-gpu because there is no GPU on the
  # instance and Electron's software fallback is less crash-prone when told up
  # front. The window title ends in "Visual Studio Code", which is what
  # KEYS_WINDOW matches on.
  cat > "$UNIT_DIR/fake-claude-vscode.service" <<EOF
[Unit]
Description=fake-claude VS Code session
After=fake-claude-desktop.service
BindsTo=fake-claude-vnc.service

[Service]
Type=simple
WorkingDirectory=$PROJECT_DIR
Environment=DISPLAY=:$DISPLAY_NUM
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
${REMOTE_URL:+Environment=FAKE_CLAUDE_URL=$REMOTE_URL}
ExecStart=/usr/bin/code --new-window --disable-gpu --wait $PROJECT_DIR
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
fi

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

if [ "${FAKE_VSCODE:-1}" != "0" ]; then
  UI_UNIT="fake-claude-vscode"
  UI_WINDOW="Visual Studio Code"
else
  UI_UNIT="fake-claude-term"
  UI_WINDOW="fakeclaude"
fi

cat <<EOF

==> done

  display   :$DISPLAY_NUM  ($GEOMETRY, listening on 127.0.0.1:$VNC_PORT)
  server    $WHERE
  session   $UI_UNIT
  project   $PROJECT_DIR

Next, from your laptop:

  1. log in, so the CLI doesn't show the connectors banner. Do it HERE, not by
     copying ~/.claude from a Mac — macOS keeps the token in the Keychain, so
     that directory holds transcripts and no credentials.
       source ~/.bashrc && claude

  2. tunnel, then point any VNC viewer at localhost:$VNC_PORT
       ssh -L $VNC_PORT:localhost:$VNC_PORT $USER@<host>

  3. back on the box, start the session and the driver
       systemctl --user start $UI_UNIT
       cd $REPO_DIR && ${DRIVER_ENV}KEYS_WINDOW='$UI_WINDOW' ./cloud/keypress-linux.sh --forever

  4. record on your own machine while the viewer is open, then close it.
     The run keeps going without you.
EOF
