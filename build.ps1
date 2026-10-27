<#
.SYNOPSIS
    Roda os testes e gera dist\Overclutch-Setup.exe com o Inno Setup 6.
    Uso: powershell -ExecutionPolicy Bypass -File build.ps1 [-SkipTests]
#>
param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'

$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 não encontrado. Instale com: winget install --id JRSoftware.InnoSetup -e' }

if (-not $SkipTests) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $PSScriptRoot 'tests\Run-Tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Os testes falharam; instalador não foi gerado.' }
}

$core = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'src\Core.ps1') -Raw
if ($core -notmatch "AppVersion\s*=\s*'([^']+)'") { throw 'Versão não encontrada em src\Core.ps1' }
$version = $Matches[1]

& $iscc "/DAppVersion=$version" (Join-Path $PSScriptRoot 'installer\Overclutch.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC falhou (código $LASTEXITCODE)." }
$exe = Join-Path $PSScriptRoot 'dist\Overclutch-Setup.exe'
Write-Host "Instalador gerado: $exe ($([math]::Round((Get-Item $exe).Length / 1KB)) KB, versão $version)"
