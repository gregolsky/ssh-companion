# Usage: .\companion.ps1 [-Layout split|windows] [-Split] [-Windows] ssh [-i key.pem] user@hostname [ssh-options...]
# Opens SSH alongside Claude in Windows Terminal, either as a split pane
# (default) or as two separate windows.
# Requires: Docker Desktop, Windows Terminal (wt), claude CLI.

param(
    [string]$Layout = "split",
    [switch]$Split,
    [switch]$Windows,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemArgs
)

if ($Split)   { $Layout = "split" }
if ($Windows) { $Layout = "windows" }
if ($Layout -notin @("split","windows")) {
    Write-Error "Invalid -Layout '$Layout' (expected: split | windows)"; exit 1
}

$dest = $RemArgs | Where-Object { $_ -notmatch '^-' -and $_ -ne 'ssh' } | Select-Object -Last 1
$hostname = ($dest -split '@')[-1]
if (-not $hostname) { Write-Error "Usage: companion.ps1 [-Split|-Windows] ssh [-i key.pem] user@hostname"; exit 1 }

$mcpList = claude mcp list 2>$null
if ($mcpList -notmatch "ssh-companion") {
    claude mcp add ssh-companion docker -- exec -i ssh-companion python /app/server.py
}

$cmd = $RemArgs -join ' '

if ($Layout -eq "split") {
    wt new-tab --title "SSH: $hostname" -- docker exec -it ssh-companion $cmd `; split-pane --vertical --title "Claude" -- powershell -NoExit -Command "claude"
} else {
    wt -w -1 new-window --title "SSH: $hostname" -- docker exec -it ssh-companion $cmd
    wt -w -1 new-window --title "Claude" -- powershell -NoExit -Command "claude"
}
