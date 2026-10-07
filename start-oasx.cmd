@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "%~dp0Start-OASX.ps1"
