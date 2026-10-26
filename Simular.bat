@echo off
rem Abre o NitroFPS em MODO SIMULACAO: mostra o que faria, sem alterar nada.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0NitroFPS.ps1" -DryRun
