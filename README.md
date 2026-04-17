# ssh-companion-mcp

![ssh-companion](icon.png)

> "I am always here if you need me, though I confess I find the most enjoyment in simply observing."
> — *Daneel Olivaw, The Caves of Steel* (Isaac Asimov)

An MCP server that lets Claude observe your SSH sessions in real time and advise on support problems — performance issues, log analysis, error detection — without touching the remote servers.

## How it works

A Docker container acts as the SSH chokepoint. Every session you open through the container is silently captured via `script -f` to a log file. The MCP server reads those logs and exposes them to Claude. Works with nested tmux on the remote, any shell, any terminal — capture happens at the raw byte stream level before anything on the remote gets involved.

```
Your terminal
    │
    │  docker exec -it ssh-companion ssh user@prod-db-1
    ▼
Container (ssh-companion-mcp)
    /usr/local/bin/ssh  ← wrapper
         │  script -q -f /sessions/prod-db-1-<ts>.log /usr/bin/ssh ...
         ▼
    /sessions/prod-db-1-*.log  ← live-appended typescript files
         ▲
    server.py  ← MCP server reads + strips ANSI
         ▲
Claude Code  →  docker exec -i ssh-companion python /app/server.py
```

## Prerequisites

- Docker
- screen (Linux) or Windows Terminal / `wt` (Windows)
- [Claude Code CLI](https://claude.ai/code)

## Setup

### 1. Build the container

```bash
git clone <this-repo>
cd ssh-companion-mcp
docker build -t ssh-companion-mcp .
```

### 2. Start the container

```bash
docker run -d --name ssh-companion \
  -v /tmp:/tmp \
  -v ~/.ssh-companion-sessions:/sessions \
  ssh-companion-mcp
```

The `/tmp` mount lets the container access ephemeral SSH keys placed there by your key-provisioning workflow (e.g. `ssh -i /tmp/temp-key`). Sessions are logged to `~/.ssh-companion-sessions/` on your host.

### 3. Register the MCP server with Claude Code

```bash
claude mcp add ssh-companion-mcp docker -- exec -i ssh-companion python /app/server.py
```

Or add manually to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "ssh-companion-mcp": {
      "command": "docker",
      "args": ["exec", "-i", "ssh-companion", "python", "/app/server.py"]
    }
  }
}
```

## Usage

### One-liner launcher (recommended)

Opens your SSH session on the left and Claude on the right, side by side.

**Linux (screen):**
```bash
chmod +x companion.sh
./companion.sh ssh ubuntu@prod-db-1
./companion.sh ssh -i /tmp/temp-key ubuntu@prod-db-1
```

**Windows (Windows Terminal):**
```powershell
.\companion.ps1 ssh ubuntu@prod-db-1
.\companion.ps1 ssh -i ~\.ssh\key.pem ubuntu@prod-db-1
```

### Manual SSH (if you prefer your own terminal layout)

```bash
# Add this alias to ~/.bashrc or ~/.zshrc
alias ssh='docker exec -it ssh-companion ssh'

# Then use ssh normally — sessions are captured automatically
ssh user@prod-db-1
```

### Ask Claude for help

Once you're in a session, switch to the Claude pane and ask:

```
What's happening on prod-db-1?
```

Claude will call `focus_session("prod-db-1")` and read the last 200 lines of your session.

### Active watch mode (`/loop`)

To have Claude monitor a session and alert you proactively:

```
/loop Watch prod-db-1 every 30 seconds. Call read_session_since with the last
byte_offset each time. Alert me if you see errors, OOM messages, high load,
or anything that looks like it needs attention.
```

## MCP Tools

| Tool | Description |
|------|-------------|
| `list_sessions()` | List all captured sessions by hostname with last-active time |
| `focus_session(hostname, lines=200)` | Read the latest session log — returns clean text + byte_offset |
| `read_session_since(hostname, byte_offset)` | Efficient poll — only new output since last read |
| `search_session(hostname, pattern)` | Grep all logs for a hostname using a Python regex |

## Multiple servers

Each server gets its own log file(s) under `/sessions/<hostname>-<timestamp>.log`. Switching between servers just means telling Claude a different hostname — it reads the right log automatically.

```
# You were on prod-db-1, now you're jumping to prod-web-2:
ssh user@prod-web-2

# In Claude:
"I'm now on prod-web-2 — what do you see?"
```

## Stopping / cleanup

```bash
# Stop the container
docker stop ssh-companion && docker rm ssh-companion

# Clear session logs (optional)
rm -rf ~/.ssh-companion-sessions
```

## Notes

- **Read-only**: Claude can only observe. No commands are sent to any session.
- **Nested tmux**: works fine. The capture is at the SSH byte stream level, so what remote tmux renders is captured as-is and ANSI-stripped for Claude.
- **No prefix clash**: `companion.sh` uses GNU `screen` locally (prefix `C-a`), so `C-b` passes cleanly through to your remote tmux session.
- **SSH keys**: the `/tmp:/tmp` mount means any key at `/tmp/temp-key` on the host is visible inside the container at the same path — use `ssh -i /tmp/temp-key` as normal. SSH agent forwarding (`-A`) is also supported.
