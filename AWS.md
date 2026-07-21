# Running fake-claude on AWS

The server is already live on Render. This sets up an EC2 box that runs VS Code
with Claude Code inside it, types prompts by itself, and **keeps running after
you close your laptop**.

```
   your laptop              EC2 t3.small                Render (free)
  ┌────────────┐           ┌────────────────────┐       ┌──────────────┐
  │ VNC viewer │◄─tunnel──►│ VS Code            │       │ kickback-kick│
  │ + your own │           │  └ terminal        │──────►│ .onrender.com│
  │   recorder │           │     └ claude       │ https │              │
  └────────────┘           │ keypress-linux.sh  │       └──────────────┘
   close it anytime;       └────────────────────┘             $0
   the run continues            ~$15/mo
```

---

## Step 1 — Launch the instance

In the EC2 console:

| Setting | Value |
|---|---|
| AMI | **Ubuntu Server 24.04 LTS** |
| Instance type | **t3.small** (2 GB RAM) |
| Key pair | create or pick one — you need it for SSH |
| Storage | 12 GB gp3 |
| Security group | **SSH (22) only** |
| Region | `us-east-2` (Ohio) — same as your Render service |

**Do not open port 5901.** VNC stays on localhost and you reach it through an
SSH tunnel.

### Picking a size

Claude Code
[documents a 4 GB minimum](https://code.claude.com/docs/en/setup#system-requirements),
but that's sized for real development — indexing large repos, running builds.
Here it replays canned responses and never reads a real codebase. What actually
runs:

| | |
|---|---|
| Xvnc + openbox | ~100 MB |
| VS Code (Electron) | ~500-700 MB |
| Claude Code | ~200-300 MB |
| **total** | **~1 GB** |

| instance | RAM | works? | ~$/mo if left on |
|---|---|---|---|
| `t3.micro` | 1 GB | only with `FAKE_VSCODE=0` | ~$7.50 (free tier eligible) |
| **`t3.small`** | 2 GB | **yes — the sensible default** | ~$15 |
| `t3.medium` | 4 GB | comfortable, unnecessary here | ~$30 |

setup.sh adds a **2 GB swap file** (skip with `FAKE_SWAP=0`), which is what makes
2 GB safe: steady state is fine, but VS Code's startup spike has little headroom,
and the OOM killer picks the largest process — the one you're filming.

**If you stop the instance between sessions, the type barely matters.** EC2
bills by the second; four hours of filming on t3.small is about 8 cents. The
monthly figures above only apply if you leave it running.

---

## Step 2 — Install everything

SSH in:

```bash
ssh -i your-key.pem ubuntu@<your-ec2-ip>
```

Then:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/ashishsigdel/kickback-kick.git fake-claude
cd fake-claude
FAKE_CLAUDE_URL=https://kickback-kick.onrender.com ./cloud/setup.sh
```

It asks you to set a VNC password, then installs and configures everything:
the VNC desktop, Claude Code, VS Code, and the services. Takes a few minutes.

Passing `FAKE_CLAUDE_URL` tells it the server is on Render, so it doesn't run
one locally.

To skip VS Code and use a plain terminal instead, prefix with `FAKE_VSCODE=0`.

---

## Step 3 — Copy your Claude credentials

**From your laptop**, in a second terminal:

```bash
scp -i your-key.pem -r ~/.claude ubuntu@<your-ec2-ip>:~/
```

Without this the CLI has no login. The workaround (`FAKE_CLAUDE_TOKEN`) makes it
print a *"claude.ai connectors are disabled"* banner, which is an obvious tell
in a recording — so copy the credentials instead.

---

## Step 4 — Connect and look at it

**From your laptop**, open the tunnel and leave it running:

```bash
ssh -i your-key.pem -L 5901:localhost:5901 ubuntu@<your-ec2-ip>
```

Then open a VNC viewer at **`localhost:5901`**:

- **macOS**: Finder → Go → Connect to Server → `vnc://localhost:5901`
- **anywhere**: [TigerVNC](https://tigervnc.org/) or RealVNC Viewer

You'll see an empty desktop. That's normal — nothing is started yet.

---

## Step 5 — Start the session

Back in your SSH session on the box:

```bash
systemctl --user start fake-claude-vscode
```

Watch the VNC window. VS Code opens your project and **automatically starts
Claude Code in its integrated terminal** — that's a `folderOpen` task the setup
wrote into `~/project/.vscode/tasks.json`. No clicking needed.

---

## Step 6 — Start the auto-typing

Still on the box:

```bash
cd ~/fake-claude
tmux new -s driver
```

Inside tmux:

```bash
FAKE_CLAUDE_URL=https://kickback-kick.onrender.com \
KEYS_WINDOW='Visual Studio Code' \
./cloud/keypress-linux.sh --forever
```

It counts down 5 seconds, then starts typing prompts into VS Code's terminal.

Press **`Ctrl-b`** then **`d`** to detach from tmux. The driver keeps running.
Come back with `tmux attach -t driver`.

### What the driver does

It doesn't read the CLI's output — it can't. It subscribes to the server's
`/events` stream and reacts:

| server says | driver does |
|---|---|
| `tool_use` | waits 0.5s, presses Enter to approve the permission prompt |
| `turn_end` | waits 3s, types the next prompt |

Options:

```bash
./cloud/keypress-linux.sh --forever          # loop the built-in 10 prompts
./cloud/keypress-linux.sh -f prompts.txt     # your own, one per line
./cloud/keypress-linux.sh 'fix the bug'      # just these
./cloud/keypress-linux.sh -n 5               # five passes
```

Timing knobs: `KEYS_TYPE_MIN_MS` / `KEYS_TYPE_MAX_MS` (per character),
`KEYS_READ_SECS` (pause between turns).

---

## Step 7 — Record, then walk away

Record on **your own machine** while the VNC window is open — QuickTime,
`Cmd-Shift-5`, OBS, whatever you use. Nothing needs to be installed on the
instance.

When you're done:

1. Stop recording
2. Close the VNC viewer
3. Close the SSH tunnel
4. Close your laptop

**The run keeps going.** Reconnect tomorrow and it's still typing.

For better capture quality, match your viewer window to the server resolution
(default `1600x900` — change with `FAKE_GEOMETRY` before running setup.sh) and
set the viewer's encoding to Tight with high quality.

---

## Why it survives you disconnecting

Three things, all handled by setup.sh:

1. **The desktop is on the server.** Xvnc is a real X display that exists
   whether or not a viewer is attached. Your VNC client is just a window onto it.
2. **`loginctl enable-linger`.** By default systemd destroys your entire user
   service manager when your last SSH session ends — this is what stops it, and
   it's the single most important line in the whole setup.
3. **tmux** holds the driver, so closing your SSH session doesn't kill it.

Verify lingering is on:

```bash
loginctl show-user $USER | grep Linger    # want: Linger=yes
```

---

## Everyday commands

```bash
# start / stop the visible session
systemctl --user start fake-claude-vscode
systemctl --user stop  fake-claude-vscode

# is everything up?
systemctl --user status fake-claude-vnc fake-claude-desktop fake-claude-vscode

# driver
tmux attach -t driver        # watch it
tmux kill-session -t driver  # stop it
```

| unit | what it is |
|---|---|
| `fake-claude-vnc` | the X display on `:1` |
| `fake-claude-desktop` | window manager, screensaver off |
| `fake-claude-vscode` | VS Code + auto-started Claude Code |
| `fake-claude-term` | plain xterm alternative (`FAKE_VSCODE=0`) |

The first two are enabled, so they return after a reboot.

---

## Troubleshooting

**Nothing gets typed.** The driver types into whatever window has focus. Click
the VS Code terminal once, or check `KEYS_WINDOW` matches the window title.

**VS Code opens but no terminal starts.** The automatic task was blocked. In VS
Code: `Ctrl-Shift-P` → *Tasks: Allow Automatic Tasks* → then restart the unit.

**First prompt of the day hangs ~50 seconds.** Render's free tier sleeps after
15 minutes idle. The scripts wait it out and print `waking …`. Expected.

**The run stalls with the CLI sitting idle.** The `/events` stream probably
reconnected and missed a `turn_end`. `tmux attach -t driver`, Ctrl-C, restart it.

**Everything dies when I disconnect.** Lingering isn't on — see above.

**Black screen.** Screensaver. `DISPLAY=:1 xset s off -dpms`.

**VS Code won't start.** Check `journalctl --user -u fake-claude-vscode -n 50`.
Usually memory. Check `free -h` shows swap active; if you're on t3.micro, run with `FAKE_VSCODE=0`.

---

## Cost

| | |
|---|---|
| Render free tier | **$0** |
| t3.small running | ~$0.021/hr, ~$15/mo if left on |
| t3.small **stopped** | ~$1/mo (just the 12 GB disk) |
| t3.small, 4 hrs of filming | **~$0.08** |

**Stop the instance in the EC2 console when you're not filming.** That's the
difference between $15/month and a few cents. Everything comes back on start,
because the services are enabled — you'll only need to re-run step 5 onward.
