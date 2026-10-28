@echo off
rem Abre o CofBoost (pede permissao de administrador).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CofBoost.ps1"
