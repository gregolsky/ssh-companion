param(
    [string]$Image = "ssh-companion-mcp",
    [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"

Write-Host "Building ${Image}:${Tag}..."
docker build -t "${Image}:${Tag}" .
Write-Host "Done: ${Image}:${Tag}"
