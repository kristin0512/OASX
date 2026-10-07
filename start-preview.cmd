@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "%~dp0dev_tools\start_preview.ps1"
