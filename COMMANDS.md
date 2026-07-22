# Screen

ssh -i ~/Desktop/kickback-kick.pem -L 5901:localhost:5901 ubuntu@3.22.126.134

vnc://localhost:5901

# KeyPress

ssh -i ~/Desktop/kickback-kick.pem ubuntu@3.22.126.134

tmux attach -t driver

# Start Session

systemctl --user start fake-claude-vscode

# Start Auto Typing

cd ~/fake-claude
tmux new -s driver

FAKE_CLAUDE_URL=https://kickback-kick.onrender.com \
KEYS_WINDOW='Visual Studio Code' \
./cloud/keypress-linux.sh --forever

# .claude

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://kickback-kick.onrender.com",
    "ANTHROPIC_MODEL": "claude-opus-4-8"
  },
  "permissions": {
    "allow": ["Bash(*)"]
  }
}
```
