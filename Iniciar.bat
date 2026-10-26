@echo off
rem Abre o NitroFPS (pede permissao de administrador).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0NitroFPS.ps1"
