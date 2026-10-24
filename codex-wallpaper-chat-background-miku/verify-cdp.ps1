param([int]$Port = 9335, [string]$ExpectedExecutable)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-process.ps1')
Assert-WallpaperCdpOwner -Port $Port -ExpectedExecutable $ExpectedExecutable
Write-Output 'verified'
