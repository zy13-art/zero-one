param([switch]$NoStart)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$command = Get-Command node.exe -ErrorAction SilentlyContinue
$node = if ($command) { $command.Source } else { Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' }
if (-not (Test-Path -LiteralPath $node -PathType Leaf)) { throw 'Node.js 22+ is required. Install it or let your local Codex locate its bundled Node runtime.' }
$version = & $node --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22) { throw 'Node.js 22+ is required.' }
& $node (Join-Path $root 'wallpaper.mjs') --validate
if ($LASTEXITCODE -ne 0) { throw 'Add a valid MP4 to wallpapers and correct settings.json before installing.' }
& (Join-Path $root 'install-autostart.ps1') -StartWithWindows
if ($NoStart) {
  Write-Host 'Startup registration is saved. Current Codex and background helpers were not restarted.'
} else {
  & (Join-Path $root 'stop.ps1') -HelpersOnly
  & (Join-Path $root 'watcher-start.ps1')
  if (-not (& (Join-Path $root 'watcher-start.ps1') -CheckOnly)) { throw 'Background startup verification failed.' }
  Write-Host 'Ready. Save your input and fully quit Codex once, then reopen using your original Codex icon.'
}
