@echo off
rem Abre o Overclutch (pede permissao de administrador).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Overclutch.ps1"
