# Copyright 2026 Grzegorz Lachowski
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Usage: .\companion.ps1 [-Layout split|windows] [-Split] [-Windows] [-InstructionsLoop "<prompt>"] ssh [-i key.pem] user@hostname [ssh-options...]
# Opens SSH alongside Claude in Windows Terminal, either as a split pane
# (default) or as two separate windows.
# -InstructionsLoop pre-seeds Claude with `/loop <prompt>` so the watch
# loop starts on launch instead of being typed by hand.
# Requires: Docker Desktop, Windows Terminal (wt), claude CLI.

param(
    [string]$Layout = "split",
    [switch]$Split,
    [switch]$Windows,
    [string]$InstructionsLoop = "",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemArgs
)

if ($Split)   { $Layout = "split" }
if ($Windows) { $Layout = "windows" }
if ($Layout -notin @("split","windows")) {
    Write-Error "Invalid -Layout '$Layout' (expected: split | windows)"; exit 1
}

# Port of ssh_log_host in _ssh-host.sh: must produce the same name the
# container's ssh-wrapper uses for the log file, so --hostname matches it.
function Get-SshLogHost([string[]]$SshArgs) {
    $withArg = 'BbcDEeFIiJLlmOoPpQRSWw'  # ssh options that take a value
    $dest = ''
    for ($i = 0; $i -lt $SshArgs.Count; $i++) {
        $a = $SshArgs[$i]
        if ($a -eq '--') { if ($i + 1 -lt $SshArgs.Count) { $dest = $SshArgs[$i + 1] }; break }
        if ($a.Length -gt 1 -and $a.StartsWith('-')) {
            $opts = $a.Substring(1)
            for ($j = 0; $j -lt $opts.Length; $j++) {
                if ($withArg.IndexOf($opts[$j]) -ge 0) {
                    # The value is the rest of this word (-p22), else the next argument.
                    if ($j + 1 -ge $opts.Length) { $i++ }
                    break
                }
            }
            continue
        }
        $dest = $a; break
    }
    $h = $dest
    if ($h.StartsWith('ssh://')) {
        $h = $h.Substring(6).Split('/')[0]
        $h = $h.Substring($h.LastIndexOf('@') + 1)
        if ($h.StartsWith('[')) { $h = $h.Substring(1).Split(']')[0] } else { $h = $h.Split(':')[0] }
    } else {
        $h = $h.Substring($h.LastIndexOf('@') + 1).TrimStart('[').TrimEnd(']')
        # One colon is a host:port typo; two or more is an IPv6 address.
        if (($h.Split(':').Count - 1) -lt 2) { $h = $h.Split(':')[0] }
    }
    $h = $h -replace '[:%]', '-'
    if ($h -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $h = 'unknown' }
    return $h
}

$sshArgs = @($RemArgs)
if ($sshArgs.Count -gt 0 -and $sshArgs[0] -eq 'ssh') { $sshArgs = @($sshArgs | Select-Object -Skip 1) }
$hostname = Get-SshLogHost $sshArgs
if ($sshArgs.Count -eq 0) { Write-Error "Usage: companion.ps1 [-Split|-Windows] [-InstructionsLoop `"<prompt>`"] ssh [-i key.pem] user@hostname"; exit 1 }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$McpFile = Join-Path $ScriptDir ".mcp.json"
$SettingsFile = Join-Path $ScriptDir ".claude\settings.local.json"
$McpLockName = "Global\ssh-companion-mcp"
$sanitizedHost = $hostname -replace '[^A-Za-z0-9_-]', '-'
$mcpSuffix = "${sanitizedHost}-${PID}"
$mcpName = "ssh-companion-${mcpSuffix}"

function Invoke-WithMcpLock([scriptblock]$Action) {
    $mutex = [System.Threading.Mutex]::new($false, $McpLockName)
    try {
        $mutex.WaitOne() | Out-Null
        & $Action
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# Adds/removes server-level allow-rules (mcp__<name>) in the per-user, gitignored
# .claude/settings.local.json. Caller must hold the MCP mutex.
function Update-McpPermissions([string[]]$Add = @(), [string[]]$Remove = @()) {
    $dir = Split-Path -Parent $SettingsFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    if (Test-Path $SettingsFile) { $s = Get-Content $SettingsFile -Raw | ConvertFrom-Json } else { $s = [PSCustomObject]@{} }
    if (-not $s.PSObject.Properties['permissions']) {
        $s | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{})
    }
    $allow = @()
    if ($s.permissions.PSObject.Properties['allow']) { $allow = @($s.permissions.allow) }
    $drop = @(@($Add) + @($Remove) | ForEach-Object { "mcp__$_" })
    $allow = @($allow | Where-Object { $_ -notin $drop }) + @($Add | ForEach-Object { "mcp__$_" })
    $s.permissions | Add-Member -NotePropertyName allow -NotePropertyValue $allow -Force
    $s | ConvertTo-Json -Depth 10 | Set-Content $SettingsFile
}

function Invoke-McpPrune {
    Invoke-WithMcpLock {
        if (-not (Test-Path $McpFile)) { return }
        $data = Get-Content $McpFile -Raw | ConvertFrom-Json
        $keys = @($data.mcpServers.PSObject.Properties.Name) | Where-Object { $_ -match '^ssh-companion-.*-(\d+)$' }
        $stale = @()
        foreach ($key in $keys) {
            $pid_ = [int]($key -split '-')[-1]
            if (-not (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) {
                $data.mcpServers.PSObject.Properties.Remove($key)
                $stale += $key
            }
        }
        $data | ConvertTo-Json -Depth 6 | Set-Content $McpFile
        if ($stale.Count -gt 0) { Update-McpPermissions -Remove $stale }
    }
}

function Add-McpEntry([string]$Name, [string]$Host) {
    Invoke-WithMcpLock {
        if (-not (Test-Path $McpFile)) {
            $example = Join-Path $ScriptDir ".mcp.json.example"
            if (Test-Path $example) { Copy-Item $example $McpFile } else { '{"mcpServers":{}}' | Set-Content $McpFile }
        }
        $data = Get-Content $McpFile -Raw | ConvertFrom-Json
        $entry = [PSCustomObject]@{ command = "docker"; args = @("exec","-i","ssh-companion","python","/app/server.py","--hostname",$Host) }
        $data.mcpServers | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
        $data | ConvertTo-Json -Depth 6 | Set-Content $McpFile
        Update-McpPermissions -Add @($Name)
    }
}

function Remove-McpEntry([string]$Name) {
    Invoke-WithMcpLock {
        if (-not (Test-Path $McpFile)) { return }
        $data = Get-Content $McpFile -Raw | ConvertFrom-Json
        $data.mcpServers.PSObject.Properties.Remove($Name)
        $data | ConvertTo-Json -Depth 6 | Set-Content $McpFile
        Update-McpPermissions -Remove @($Name)
    }
}

$containerCheck = docker container inspect ssh-companion 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting ssh-companion container..."
    & "$ScriptDir\start-mcp-server.sh"
}

Invoke-McpPrune
Add-McpEntry $mcpName $hostname

# wt treats ';' as its own command separator, so escape it, and quote
# arguments containing spaces so they reach ssh as single arguments.
$cmd = ($RemArgs | ForEach-Object {
    $a = $_ -replace ';', '\;'
    if ($a -match '\s') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
}) -join ' '

# Session output is untrusted, so the companion Claude is observe-only.
$claudeFlags = "--disallowedTools Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch"
if ($InstructionsLoop) {
    $escaped = $InstructionsLoop -replace "'", "''"
    $claudeCmd = "claude '/loop $escaped' $claudeFlags"
} else {
    $claudeCmd = "claude $claudeFlags"
}

if ($Layout -eq "split") {
    try {
        Start-Process wt -ArgumentList "new-tab --title `"SSH: $hostname`" -- docker exec -it -e `"COMPANION_HOST_USER=$env:USERNAME`" ssh-companion $cmd `; split-pane --vertical --title `"Claude`" -- powershell -NoExit -Command $claudeCmd" -Wait
    } finally {
        Remove-McpEntry $mcpName
    }
} else {
    # --windows layout: wt detaches immediately; cleanup runs on next launch via Invoke-McpPrune.
    wt -w -1 new-window --title "SSH: $hostname" -- docker exec -it -e COMPANION_HOST_USER=$env:USERNAME ssh-companion @($RemArgs | ForEach-Object { $_ -replace ';', '\;' })
    wt -w -1 new-window --title "Claude" -- powershell -NoExit -Command $claudeCmd
}
