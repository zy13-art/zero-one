param([switch]$StopWatcher)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $env:LOCALAPPDATA 'CodexChatWallpaper\shortcuts.json'

function Test-OwnedWallpaperShortcut {
  param($Record, $Shortcut)
  if (-not $Record -or -not $Shortcut -or -not $Record.path) { return $false }
  if ([IO.Path]::GetFileName($Record.path) -cnotin @('Codex 动态壁纸.lnk', 'Codex Wallpaper Watcher.lnk')) { return $false }
  return $Record.description -eq 'Codex dynamic wallpaper helper' -and
    $Shortcut.Description -eq $Record.description -and $Shortcut.TargetPath -ieq $Record.target -and
    $Shortcut.Arguments -ceq $Record.arguments
}

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $shell = New-Object -ComObject WScript.Shell
  $remaining = @()
  foreach ($record in @($manifest.links)) {
    if (-not $record.path -or -not (Test-Path -LiteralPath $record.path -PathType Leaf)) { continue }
    $link = $shell.CreateShortcut($record.path)
    if (Test-OwnedWallpaperShortcut $record $link) {
      Remove-Item -LiteralPath $record.path -Force
      Write-Host ('Removed shortcut: ' + $record.path)
    } else {
      $remaining += $record
      Write-Warning ('Kept a shortcut that was changed after installation: ' + $record.path)
    }
  }
  if ($remaining.Count) {
    @{ version = 1; links = $remaining } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  } else { Remove-Item -LiteralPath $manifestPath -Force }
}
# Removing startup integration also stops both owned background helpers.
# Keep the old switch accepted for compatibility with existing instructions.
& (Join-Path $toolRoot 'stop.ps1')
