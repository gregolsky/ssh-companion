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

$dest = $RemArgs | Where-Object { $_ -notmatch '^-' -and $_ -ne 'ssh' } | Select-Object -Last 1
$hostname = ($dest -split '@')[-1]
if (-not $hostname) { Write-Error "Usage: companion.ps1 [-Split|-Windows] [-InstructionsLoop `"<prompt>`"] ssh [-i key.pem] user@hostname"; exit 1 }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$McpFile = Join-Path $ScriptDir ".mcp.json"
$McpLockName = "Global\ssh-companion-mcp"
$sanitizedHost = $hostname -replace '[.:]', '-'
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

function Invoke-McpPrune {
    Invoke-WithMcpLock {
        if (-not (Test-Path $McpFile)) { return }
        $data = Get-Content $McpFile -Raw | ConvertFrom-Json
        $keys = @($data.mcpServers.PSObject.Properties.Name) | Where-Object { $_ -match '^ssh-companion-.*-(\d+)$' }
        foreach ($key in $keys) {
            $pid_ = [int]($key -split '-')[-1]
            try { $p = Get-Process -Id $pid_ -ErrorAction Stop; $_ = $p } catch { $data.mcpServers.PSObject.Properties.Remove($key) }
        }
        $data | ConvertTo-Json -Depth 6 | Set-Content $McpFile
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
    }
}

function Remove-McpEntry([string]$Name) {
    Invoke-WithMcpLock {
        if (-not (Test-Path $McpFile)) { return }
        $data = Get-Content $McpFile -Raw | ConvertFrom-Json
        $data.mcpServers.PSObject.Properties.Remove($Name)
        $data | ConvertTo-Json -Depth 6 | Set-Content $McpFile
    }
}

$containerCheck = docker container inspect ssh-companion 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting ssh-companion container..."
    & "$ScriptDir\start-mcp-server.sh"
}

Invoke-McpPrune
Add-McpEntry $mcpName $hostname

$cmd = $RemArgs -join ' '

if ($InstructionsLoop) {
    $escaped = $InstructionsLoop -replace "'", "''"
    $claudeCmd = "claude '/loop $escaped'"
} else {
    $claudeCmd = "claude"
}

if ($Layout -eq "split") {
    try {
        Start-Process wt -ArgumentList "new-tab --title `"SSH: $hostname`" -- docker exec -it ssh-companion $cmd `; split-pane --vertical --title `"Claude`" -- powershell -NoExit -Command $claudeCmd" -Wait
    } finally {
        Remove-McpEntry $mcpName
    }
} else {
    # --windows layout: wt detaches immediately; cleanup runs on next launch via Invoke-McpPrune.
    wt -w -1 new-window --title "SSH: $hostname" -- docker exec -it ssh-companion $cmd
    wt -w -1 new-window --title "Claude" -- powershell -NoExit -Command $claudeCmd
}
