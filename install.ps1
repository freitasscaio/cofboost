<#
.SYNOPSIS
    Instalação rápida para desenvolvimento (sem o assistente): copia o Overclutch para
    %LOCALAPPDATA%\Programs\Overclutch e cria atalhos. Para usuários finais, use o
    instalador dist\Overclutch-Setup.exe gerado pelo build.ps1.
    Uso: powershell -ExecutionPolicy Bypass -File install.ps1 [-Uninstall]
#>
param([switch]$Uninstall)

$appName   = 'Overclutch'
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

New-Item -ItemType Directory -Path (Join-Path $target 'src'), (Join-Path $target 'assets') -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'Overclutch.ps1'), (Join-Path $PSScriptRoot 'Iniciar.bat'), (Join-Path $PSScriptRoot 'Simular.bat') -Destination $target -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'src\*') -Destination (Join-Path $target 'src') -Recurse -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'assets\overclutch.ico') -Destination (Join-Path $target 'assets') -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File

$shell = New-Object -ComObject WScript.Shell
foreach ($s in $shortcuts) {
    $lnk = $shell.CreateShortcut($s)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$target\Overclutch.ps1`""
    $lnk.WorkingDirectory = $target
    $lnk.IconLocation = Join-Path $target 'assets\overclutch.ico'
    $lnk.Description = 'Overclutch - otimizador para jogos'
    $lnk.Save()
}

# Remove a instalação da época em que o app se chamava NitroFPS (os dados em ProgramData são migrados pelo app).
$legacy = Join-Path $env:LOCALAPPDATA 'Programs\NitroFPS'
if (Test-Path -LiteralPath $legacy) {
    Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($s in $shortcuts) { Remove-Item -LiteralPath ($s -replace "$appName\.lnk$", 'NitroFPS.lnk') -Force -ErrorAction SilentlyContinue }
    Write-Host 'Versão antiga (NitroFPS) removida.'
}

Write-Host "$appName instalado em $target"
Write-Host 'Atalhos criados na Área de Trabalho e no Menu Iniciar.'
