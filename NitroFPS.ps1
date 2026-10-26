<#
.SYNOPSIS
    NitroFPS - otimizador de Windows para jogos.
.PARAMETER DryRun
    Modo simulação: mostra no registro o que seria alterado, sem mudar nada no PC.
#>
param([switch]$DryRun)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $DryRun) {
    # Reabre como administrador (o Windows mostra o aviso do UAC).
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show('O NitroFPS precisa de permissão de administrador para otimizar o Windows.', 'NitroFPS', 'OK', 'Warning') | Out-Null
    }
    exit
}

$src = Join-Path $PSScriptRoot 'src'
. (Join-Path $src 'Core.ps1')
. (Join-Path $src 'Tweaks.ps1')
. (Join-Path $src 'Games.ps1')
. (Join-Path $src 'UI.ps1')

try {
    Initialize-Core -DryRun:$DryRun
    Start-App
} catch {
    Write-Log "Erro fatal: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
    [System.Windows.MessageBox]::Show("Erro ao iniciar o NitroFPS:`n$($_.Exception.Message)", 'NitroFPS', 'OK', 'Error') | Out-Null
}
