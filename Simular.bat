@echo off
rem Abre o Overclutch em MODO SIMULACAO: mostra o que faria, sem alterar nada.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Overclutch.ps1" -DryRun
