<#
.SYNOPSIS
    Testes do NitroFPS. Não alteram o sistema: os ajustes rodam em modo simulação e o
    teste de backup/reversão usa apenas a chave de teste HKCU:\Software\NitroFPS-Test (apagada no fim).
    Uso: powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:Failures = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "  OK   $Message" -ForegroundColor Green }
    else { Write-Host "  FALHA $Message" -ForegroundColor Red; $script:Failures++ }
}

Write-Host 'Sintaxe dos scripts'
foreach ($f in Get-ChildItem -Path $root -Recurse -Filter *.ps1) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) "$($f.Name) $(($errors | ForEach-Object { $_.Message }) -join '; ')"
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "$($f.Name) salvo em UTF-8 com BOM (acentos no PowerShell 5.1)"
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $root 'src\Core.ps1')
. (Join-Path $root 'src\Tweaks.ps1')
. (Join-Path $root 'src\Games.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("nitrofps-test-" + [guid]::NewGuid())

Write-Host 'Catálogo de otimizações'
$ids = $script:Tweaks | ForEach-Object { $_.Id }
Assert (($ids | Sort-Object -Unique).Count -eq $ids.Count) 'Ids únicos'
foreach ($t in $script:Tweaks) {
    $ok = $t.Id -and $t.Name -and $t.Description -and $t.Category -and $t.Risk -and ($t.Registry -or $t.Services -or $t.Apply)
    Assert $ok "$($t.Id) tem os campos obrigatórios"
    foreach ($r in $t.Registry) {
        $validType = [enum]::GetNames([Microsoft.Win32.RegistryValueKind]) -contains $r.Type
        Assert (($r.Path -match '^(HKLM|HKCU):\\') -and $validType) "$($t.Id): $($r.Name) tem caminho e tipo válidos"
    }
}

Write-Host 'Modo simulação (nenhuma escrita)'
Initialize-Core -DataDir $tmp -DryRun
foreach ($t in $script:Tweaks) {
    $before = Test-TweakApplied $t
    try { Invoke-Tweak $t; $applied = $true } catch { $applied = $false; Write-Host "     $($_.Exception.Message)" }
    Assert $applied "$($t.Id) simulado (estado atual: $(if ($before) { 'ativo' } else { 'inativo' }))"
    Assert ((Test-TweakApplied $t) -eq $before) "$($t.Id) não mudou o sistema"
}
Assert (-not (Test-Path (Join-Path $tmp 'backup.json'))) 'Nenhum backup gravado em simulação'

Write-Host 'Backup e reversão reais (chave de teste)'
Remove-Item -Path $tmp -Recurse -Force
Initialize-Core -DataDir $tmp
$key = 'HKCU:\Software\NitroFPS-Test'
Set-RegValueRaw $key 'Existente' 5 'DWord'
Set-RegValueRaw $key 'Texto' 'original' 'String'
$fake = @{
    Id = 'teste'; Name = 'Teste'
    Registry = @(
        (RegSet $key 'Existente' 1)
        (RegSet $key 'Texto' 'novo' 'String')
        (RegSet $key 'Novo' -1)
        (RegSet "$key\Sub" 'Valor' 7)
    )
}
Invoke-Tweak $fake
Invoke-Tweak $fake   # aplicar duas vezes não pode sobrescrever o backup original
Assert (Test-TweakApplied $fake) 'Ajuste aplicado'
Assert ((Get-RegValue $key 'Novo').Value -eq -1) 'DWORD 0xFFFFFFFF gravado'
Assert (@(Get-BackupEntries 'teste').Count -eq 4) 'Backup tem 4 entradas (sem duplicar)'

# Recarrega o backup do disco, como se o app tivesse sido fechado e aberto de novo.
Initialize-Core -DataDir $tmp
Undo-Tweak $fake
Assert ((Get-RegValue $key 'Existente').Value -eq 5) 'Valor DWORD original restaurado'
Assert ((Get-RegValue $key 'Texto').Value -eq 'original') 'Valor String original restaurado'
Assert (-not (Get-RegValue $key 'Novo')) 'Valor que não existia foi removido'
Assert (-not (Get-RegValue "$key\Sub" 'Valor')) 'Valor em subchave nova foi removido'
Assert (@(Get-BackupEntries 'teste').Count -eq 0) 'Backup limpo após reverter'
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\NitroFPS-Test', $false)

Write-Host 'Limpeza de temporários (pasta falsa)'
$fakeTemp = Join-Path $tmp 'temp'
$outside  = Join-Path $tmp 'fora'
New-Item -ItemType Directory -Path "$fakeTemp\a\b", $outside -Force | Out-Null
Set-Content "$fakeTemp\solto.txt" 'x'
Set-Content "$fakeTemp\a\b\fundo.txt" 'x'
Set-Content "$fakeTemp\a\somente-leitura.txt" 'x'; (Get-Item "$fakeTemp\a\somente-leitura.txt").IsReadOnly = $true
Set-Content "$fakeTemp\a\em-uso.txt" 'x'
Set-Content "$outside\importante.txt" 'nao apagar'
cmd /c mklink /J "$fakeTemp\juncao" "$outside" | Out-Null
$lock = [IO.File]::Open("$fakeTemp\a\em-uso.txt", 'Open', 'Read', 'None')
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Clear-TempFiles -Paths @($fakeTemp)
    Assert ($sw.Elapsed.TotalSeconds -lt 10) "Limpeza terminou sem travar ($([int]$sw.Elapsed.TotalMilliseconds) ms)"
} finally { $lock.Close() }
Assert ($r.Files -eq 3 -and $r.Skipped -eq 1) "3 apagados, 1 em uso mantido (apagou $($r.Files), manteve $($r.Skipped))"
Assert (Test-Path "$fakeTemp\a\em-uso.txt") 'Arquivo em uso continua lá'
Assert (-not (Test-Path "$fakeTemp\a\b")) 'Subpasta vazia removida'
Assert (Test-Path "$outside\importante.txt") 'Junção NÃO foi seguida (arquivo fora do TEMP intacto)'
cmd /c rmdir "$fakeTemp\juncao" | Out-Null

Write-Host 'Execução em segundo plano'
. (Join-Path $root 'src\UI.ps1')
function Set-Status { param($Text) }   # sem janela nos testes
New-Item -ItemType Directory -Path "$fakeTemp\c" -Force | Out-Null
1..5 | ForEach-Object { Set-Content "$fakeTemp\c\$_.tmp" 'x' }
$script:Core.DryRun = $false
$bg = Invoke-InBackground 'teste' "param(`$p) Clear-TempFiles -Paths @('$fakeTemp') -Progress `$p"
Assert ($bg.Files -eq 6) "Limpeza em segundo plano retornou resultado ($($bg.Files) arquivos)"

Write-Host 'Jogos'
Initialize-Core -DataDir $tmp -DryRun
$found = @(Find-InstalledGames)
Assert $true "Detecção rodou: $($found.Count) jogo(s) encontrado(s) $(($found | ForEach-Object Name) -join ', ')"
Add-Game 'Jogo Teste' 'C:\Jogos\teste.exe' | Out-Null
Import-Games
Assert ($script:Games.Count -eq 1 -and $script:Games[0].Path -eq 'C:\Jogos\teste.exe') 'Lista de jogos salva e recarregada'
Invoke-GameBoost $script:Games[0]
Assert (-not (Test-GameBoosted $script:Games[0])) 'Boost de jogo simulado sem escrever'

Write-Host 'Interface'
[xml]$xml = Get-Content -LiteralPath (Join-Path $root 'src\MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
Assert ($null -ne $window) 'XAML carrega'
foreach ($n in @('BtnBoost', 'BtnUndoAll', 'TweakList', 'GameList', 'LogBox', 'StatusText', 'ContentHost', 'BusyBar') + ('Home', 'Tweaks', 'Games', 'Tools', 'Log' | ForEach-Object { "Page$_"; "Nav$_" })) {
    Assert ($null -ne $window.FindName($n)) "Controle $n existe"
}

Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) { Write-Host "$script:Failures teste(s) falharam." -ForegroundColor Red; exit 1 }
Write-Host 'Todos os testes passaram.' -ForegroundColor Green
