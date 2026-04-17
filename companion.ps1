# Usage: .\companion.ps1 ssh [-i key.pem] user@hostname [ssh-options...]
# Opens a Windows Terminal tab with SSH on the left and Claude on the right.
# Requires: Docker Desktop, Windows Terminal (wt), claude CLI.

$dest = $args | Where-Object { $_ -notmatch '^-' -and $_ -ne 'ssh' } | Select-Object -Last 1
$hostname = ($dest -split '@')[-1]
if (-not $hostname) { Write-Error "Usage: companion.ps1 ssh [-i key.pem] user@hostname"; exit 1 }

$mcpList = claude mcp list 2>$null
if ($mcpList -notmatch "ssh-companion") {
    claude mcp add ssh-companion docker -- exec -i ssh-companion python /app/server.py
}

$cmd = $args -join ' '
wt new-tab --title "SSH: $hostname" -- docker exec -it ssh-companion $cmd `; split-pane --vertical --title "Claude" -- powershell -NoExit -Command "claude"
