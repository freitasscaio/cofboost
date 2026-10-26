<#
.SYNOPSIS
    Instala o NitroFPS em %LOCALAPPDATA%\Programs\NitroFPS e cria atalhos na Área de Trabalho e no Menu Iniciar.
    Uso: powershell -ExecutionPolicy Bypass -File install.ps1 [-Uninstall]
#>
param([switch]$Uninstall)

$appName   = 'NitroFPS'
$target    = Join-Path $env:LOCALAPPDATA "Programs\$appName"
$shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Programs')) "$appName.lnk")
)

if ($Uninstall) {
    foreach ($s in $shortcuts) { Remove-Item -LiteralPath $s -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Write-Host "$appName desinstalado. (Para desfazer as otimizações, use 'Desfazer todas' no app ANTES de desinstalar.)"
    return
}

New-Item -ItemType Directory -Path (Join-Path $target 'src') -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'NitroFPS.ps1'), (Join-Path $PSScriptRoot 'Iniciar.bat'), (Join-Path $PSScriptRoot 'Simular.bat') -Destination $target -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'src\*') -Destination (Join-Path $target 'src') -Recurse -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File

$shell = New-Object -ComObject WScript.Shell
foreach ($s in $shortcuts) {
    $lnk = $shell.CreateShortcut($s)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$target\NitroFPS.ps1`""
    $lnk.WorkingDirectory = $target
    $lnk.IconLocation = Join-Path $env:SystemRoot 'System32\powercpl.dll,0'
    $lnk.Description = 'NitroFPS - otimizador para jogos'
    $lnk.Save()
}

Write-Host "$appName instalado em $target"
Write-Host 'Atalhos criados na Área de Trabalho e no Menu Iniciar.'
