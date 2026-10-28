@echo off
rem Abre o CofBoost em MODO SIMULACAO: mostra o que faria, sem alterar nada.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CofBoost.ps1" -DryRun
