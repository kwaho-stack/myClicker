@echo off
rem ASCII-only launcher. Real work is done by MyClicker.ps1 (UTF-8 with BOM).
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0MyClicker.ps1"
