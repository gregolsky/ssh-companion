# Usage: .\peep.ps1 ssh [-i key.pem] user@hostname [ssh-options...]
# Opens a Windows Terminal tab with SSH on the left and Claude on the right.
# Requires: Docker Desktop, Windows Terminal (wt), claude CLI.

$dest = $args | Where-Object { $_ -notmatch '^-' -and $_ -ne 'ssh' } | Select-Object -Last 1
$hostname = ($dest -split '@')[-1]
if (-not $hostname) { Write-Error "Usage: peep.ps1 ssh [-i key.pem] user@hostname"; exit 1 }

$cmd = $args -join ' '
wt new-tab --title "SSH: $hostname" -- docker exec -it peep $cmd `; split-pane --vertical --title "Claude" -- powershell -NoExit -Command "claude"
