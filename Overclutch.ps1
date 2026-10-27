<#
.SYNOPSIS
    Overclutch - otimizador de Windows para jogos.
.PARAMETER DryRun
    Modo simulação: mostra no registro o que seria alterado, sem mudar nada no PC.
.PARAMETER UndoAll
    Sem interface: reverte todas as otimizações e sai (usado pelo desinstalador).
    Código de saída 0 = tudo revertido, 1 = algo ficou no backup.
#>
param([switch]$DryRun, [switch]$UndoAll)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $DryRun) {
    # Reabre como administrador (o Windows mostra o aviso do UAC).
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    if ($UndoAll) { $argList += ' -UndoAll' }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru -Wait:$UndoAll
        if ($UndoAll) { exit $p.ExitCode }
    } catch {
        [System.Windows.MessageBox]::Show('O Overclutch precisa de permissão de administrador para otimizar o Windows.', 'Overclutch', 'OK', 'Warning') | Out-Null
        if ($UndoAll) { exit 1 }
    }
    exit
}

$src = Join-Path $PSScriptRoot 'src'
. (Join-Path $src 'Core.ps1')
. (Join-Path $src 'Tweaks.ps1')
. (Join-Path $src 'Games.ps1')
if (Test-Path -LiteralPath (Join-Path $src 'Update.ps1')) { . (Join-Path $src 'Update.ps1') }
. (Join-Path $src 'UI.ps1')

if ($UndoAll) {
    Initialize-Core -DryRun:$DryRun
    Write-Log 'Revertendo tudo (chamado pelo desinstalador).'
    Undo-All
    exit $(if (@(Get-BackedUpIds).Count) { 1 } else { 0 })
}

try {
    Initialize-Core -DryRun:$DryRun
    Start-App
} catch {
    Write-Log "Erro fatal: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
    [System.Windows.MessageBox]::Show("Erro ao iniciar o Overclutch:`n$($_.Exception.Message)", 'Overclutch', 'OK', 'Error') | Out-Null
}
