# Deploying fake-claude

Split across two places: the mock server on **Render's free tier**, and the
desktop + CLI + driver on a **small EC2 instance**. Recording happens on your
own machine, over VNC, whenever you feel like watching.

```
   your laptop                EC2 t3.small                 Render (free)
  ┌────────────┐             ┌──────────────────┐         ┌──────────────┐
  │ VNC viewer │◄──tunnel───►│ Xvnc :1          │         │ mock_server  │
  │ + your own │             │  └ openbox       │         │ :443 https   │
  │   recorder │             │     └ xterm      │──────►  │              │
  └────────────┘             │        └ claude  │  https  │  /v1/messages│
    attach, record,          │ keypress-linux   │──────►  │  /events     │
    close — run continues    └──────────────────┘         └──────────────┘
                                  ~$15/mo                       $0
```

**Why this split works:** `fakeclaude` and `drive.sh` already read a full base
URL from `FAKE_CLAUDE_URL` (drive.sh:88), so pointing them at an `https://` host
needs no code change. And `/events` self-pings every 15 seconds
(mock_server.py:805-809), which keeps the SSE stream alive through Render's
proxy idle timeout.

---

## Part 1 — Server on Render

`render.yaml` in the repo root is a blueprint; Render reads it and configures
everything.

1. Push this repo to GitHub. **Make sure `scripts/` is committed** — those are
   the `@1`…`@10` transcripts, and without them the server has nothing to play.
2. Render dashboard → **New → Blueprint** → pick the repo.
3. Deploy. You get `https://fake-claude-server-xxxx.onrender.com`.

Check it:

```bash
curl https://<your-service>.onrender.com/health     # {"ok":true}
```

The blueprint sets `HOST=0.0.0.0` (the `127.0.0.1` default would be unreachable
inside a container) and lets Render inject `$PORT`. `mock_server.py` already
reads both from the environment (mock_server.py:98-99), so no code changed.

`.env` is gitignored and therefore absent on Render — every setting the run
depends on is spelled out in `render.yaml` instead. Note `SCRIPT_LOOP=false`:
with looping on, a transcript never ends, and an unattended driver waits on a
`turn_end` that never comes.

### Free-tier behaviour you need to know

**It sleeps after ~15 minutes idle and takes ~50s to wake.** All three scripts
now wait that out instead of reporting a dead server — they print
`waking https://… (up to 90s)` and dot along until it answers. Tune with
`FAKE_CLAUDE_WAKE_SECS`. Once a run is going the constant traffic keeps it up.

**Restarts drop the SSE stream.** `keypress-linux.sh` reconnects automatically
rather than exiting. It's not seamless — events emitted while disconnected are
lost, and a missed `turn_end` leaves the driver waiting forever. If a run stalls
with the CLI plainly idle, that's this: Ctrl-C and restart.

**750 instance-hours/month**, plenty for one sleepy service.

**The URL is public.** It only ever serves canned text, so there's not much to
steal, but anyone who finds it can burn your instance hours. Don't post it.

---

## Part 2 — EC2

| | |
|---|---|
| type | `t3.small` (2 GB) — X + xterm + the CLI won't fit comfortably in t3.micro's 1 GB |
| AMI | Ubuntu Server 24.04 LTS |
| disk | 8 GB is fine — nothing gets recorded here |
| cost | ~$0.0208/hr, ~$15/mo running continuously |
| ports | **inbound SSH (22) only** |

Do not open 5901. VNC stays bound to localhost and you reach it through an SSH
tunnel, so a weak VNC password can't cost you the box.

```bash
sudo apt-get update && sudo apt-get install -y git
git clone <your-repo-url> fake-claude
cd fake-claude
FAKE_CLAUDE_URL=https://<your-service>.onrender.com ./cloud/setup.sh
```

Passing `FAKE_CLAUDE_URL` tells setup.sh the server is somebody else's problem:
it skips the local server unit entirely (and removes a stale one, which would
otherwise answer on 127.0.0.1 and quietly win), and bakes the URL into the
terminal service.

**Lingering is what makes it survive disconnect.** By default systemd kills your
entire user service manager when your last SSH session ends. `setup.sh` runs
`loginctl enable-linger` to stop that.

### Credentials

The one step with a trap. `fakeclaude` deliberately leaves
`ANTHROPIC_AUTH_TOKEN` unset, because setting it makes the CLI print a
*"claude.ai connectors are disabled"* banner — an obvious tell on camera. Copy
your login over instead:

```bash
scp -r ~/.claude ubuntu@<host>:~/
```

---

## Part 3 — Run and record

Open the tunnel from your laptop:

```bash
ssh -L 5901:localhost:5901 ubuntu@<host>
```

Point a VNC viewer at **`localhost:5901`**:

- **macOS** — Finder → Go → Connect to Server → `vnc://localhost:5901`
- **anywhere** — [TigerVNC](https://tigervnc.org/) or RealVNC Viewer

On the box:

```bash
systemctl --user start fake-claude-term
cd ~/fake-claude && ./cloud/keypress-linux.sh --forever
```

Then record locally — QuickTime, OBS, `Cmd-Shift-5`, whatever you use — while
the viewer is open. Close it when you have what you need. **The run doesn't
notice.** Come back in an hour and it's still going, mid-transcript.

Run the driver under `tmux` so you can detach from it too:

```bash
tmux new -s driver
FAKE_CLAUDE_URL=https://<your-service>.onrender.com ./cloud/keypress-linux.sh --forever
# ctrl-b d to detach, `tmux attach -t driver` to return
```

### Recording quality over VNC

You're recording a VNC client, not the framebuffer, so you inherit its
compression. Two things help a lot:

- Match your viewer window to the server geometry for 1:1 pixels. Default is
  `1600x900`; change it with `FAKE_GEOMETRY` before running setup.sh.
- Set the viewer's encoding to **Tight + high quality** or raw over the tunnel.

If you later want a pixel-perfect capture, add ffmpeg's `x11grab` back on the
instance — it records the real framebuffer and ignores VNC entirely.

### Which driver?

| | how | needs a screen? |
|---|---|---|
| `drive.sh` | spawns the CLI on its own pty via `expect` | no |
| `cloud/keypress-linux.sh` | types into the xterm on `:1` via xdotool | yes |

Use `keypress-linux.sh` here — you want the visible desktop. `drive.sh` is the
headless option if you ever just want a transcript.

---

## Services

All `systemctl --user`, no sudo:

| unit | what |
|---|---|
| `fake-claude-vnc` | the X display, `:1` on `127.0.0.1:5901` |
| `fake-claude-desktop` | openbox + screensaver/DPMS off |
| `fake-claude-term` | xterm titled `fakeclaude` running the CLI |
| `fake-claude-server` | **only if you didn't pass `FAKE_CLAUDE_URL`** |

```bash
systemctl --user status fake-claude-term
journalctl --user -u fake-claude-term -f
```

VNC and desktop are enabled, so they return after a reboot. The terminal is
manual.

---

## Troubleshooting

**Everything dies when I disconnect.** Lingering didn't take. `loginctl show-user
$USER | grep Linger` — if `no`, run `sudo loginctl enable-linger $USER`.

**Keystrokes go nowhere.** The driver types into whatever window has focus on
`:1`. If your terminal's title isn't `fakeclaude`, set `KEYS_WINDOW`.

There's a subtlety worth knowing: `xdotool type --window <id>` looks like it
should remove the focus requirement, but it sends `XSendEvent`, which terminals
ignore by default — prompts vanish silently. The script activates the window and
sends real XTEST events, re-asserting focus before each prompt.

**First launch of the day hangs ~50s.** That's the Render cold start. Expected.

**The run stalls with the CLI idle.** Probably a dropped `turn_end` after a
reconnect. Ctrl-C the driver and restart it.

**`/events returned 404`.** That server predates the endpoint — redeploy on
Render.

**Screen is black.** X screensaver. The desktop unit runs `xset s off -dpms` and
so does the driver, but anything you start by hand outside those needs it too.

**Text is tiny.** Edit geometry/font in
`~/.config/systemd/user/fake-claude-term.service`, then `daemon-reload` and
restart it.

---

## Cost

| | |
|---|---|
| Render free tier | **$0** |
| `t3.small` 24/7 | ~$15/mo |
| `t3.small` stopped | ~$0.64/mo (8 GB EBS only) |

**Stop the instance when you're not filming.** EC2 bills by the second while
running; a stopped instance only costs its disk. That's the difference between
$15/mo and pocket change, and the desktop comes back on boot because the units
are enabled.
