@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo Installation was not completed. Read the error above.
  pause
  exit /b 1
)
echo Installation complete. Your current Codex window was preserved.
pause
