<#
.SYNOPSIS
    Testes do Overclutch. Não alteram o sistema: os ajustes rodam em modo simulação e o
    teste de backup/reversão usa apenas a chave de teste HKCU:\Software\Overclutch-Test (apagada no fim).
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
. (Join-Path $root 'src\Update.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("overclutch-test-" + [guid]::NewGuid())

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
$key = 'HKCU:\Software\Overclutch-Test'
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
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\Overclutch-Test', $false)

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

Assert ((Format-Size 500) -eq '1 KB' -and (Format-Size (3MB)) -match '^3[,.]0 MB$' -and (Format-Size (2GB)) -match '^2[,.]0 GB$') 'Tamanho formatado em KB, MB e GB'

Write-Host 'Execução em segundo plano'
. (Join-Path $root 'src\UI.ps1')
function Set-Status { param($Text) }   # sem janela nos testes
New-Item -ItemType Directory -Path "$fakeTemp\c" -Force | Out-Null
1..5 | ForEach-Object { Set-Content "$fakeTemp\c\$_.tmp" 'x' }
$script:Core.DryRun = $false
$bg = Invoke-InBackground 'teste' "param(`$p) Clear-TempFiles -Paths @('$fakeTemp') -Progress `$p"
Assert ($bg.Files -eq 6) "Limpeza em segundo plano retornou resultado ($($bg.Files) arquivos)"

Write-Host 'Atualização'
Assert (Test-NewerVersion '1.0.2' '1.0.1') '1.0.2 é mais nova que 1.0.1'
Assert (Test-NewerVersion '1.10.0' '1.9.0') '1.10.0 é mais nova que 1.9.0 (compara número, não texto)'
Assert (-not (Test-NewerVersion '1.0.1' '1.0.1')) 'Mesma versão não pede atualização'
Assert (-not (Test-NewerVersion 'abc' '1.0.1')) 'Versão inválida não pede atualização'
$good = [pscustomobject]@{ Version = '1.2.0'; Url = 'https://github.com/freitasscaio/overclutch/releases/download/v1.2.0/Overclutch-Setup.exe'; Size = 1; Sha256 = ('a' * 64) }
Assert (Test-ReleaseInfo $good) 'Release do repositório oficial é aceita'
Assert (-not (Test-ReleaseInfo ($good | Select-Object *, @{ n = 'Url'; e = { 'https://evil.example/Overclutch-Setup.exe' } } -ExcludeProperty Url))) 'URL de outro site é recusada'
Assert (-not (Test-ReleaseInfo ($good | Select-Object *, @{ n = 'Version'; e = { "1.0'; rm -r C:\" } } -ExcludeProperty Version))) 'Versão com caracteres estranhos é recusada'
Assert (-not (Test-ReleaseInfo ($good | Select-Object *, @{ n = 'Sha256'; e = { 'xyz' } } -ExcludeProperty Sha256))) 'SHA-256 inválido é recusado'
$bgUpdate = Invoke-InBackground 'teste' 'param($p) Test-NewerVersion "2.0" "1.0"'
Assert ($bgUpdate -eq $true) 'Módulo de atualização carrega em segundo plano'

Write-Host 'Configurações'
Initialize-Core -DataDir (Join-Path $tmp 'settings-test')
Assert ((Get-Setting 'CheckUpdates') -eq $true -and (Get-Setting 'RestorePointBeforeBoost') -eq $true) 'Padrões: verificar atualizações e criar ponto de restauração'
Set-Setting 'CheckUpdates' $false
Assert ((Get-Setting 'CheckUpdates') -eq $false -and (Get-Setting 'RestorePointBeforeBoost') -eq $true) 'Configuração salva sem apagar as outras'

Write-Host 'Limpeza em simulação (nada é apagado)'
Initialize-Core -DataDir (Join-Path $tmp 'clean-test') -DryRun
$explorer = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
$thumbsBefore = @(Get-ChildItem $explorer -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' }).Count
$r = Clear-ThumbnailCache
$thumbsAfter = @(Get-ChildItem $explorer -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' }).Count
Assert ($r.Files -eq $thumbsBefore -and $thumbsAfter -eq $thumbsBefore) "Miniaturas contadas sem apagar ($($r.Files) arquivos)"
$binBefore = (Get-RecycleBinInfo).Files
$bin = Clear-RecycleBinSafe
Assert ($bin.Files -eq $binBefore -and (Get-RecycleBinInfo).Files -eq $binBefore) "Lixeira contada sem esvaziar ($($bin.Files) itens)"
Assert ($null -ne (Clear-WindowsUpdateCache)) 'Cache do Windows Update contado'

Write-Host 'Interface'
[xml]$xml = Get-Content -LiteralPath (Join-Path $root 'src\MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
Assert ($null -ne $window) 'XAML carrega'
foreach ($n in @('BtnBoost', 'BtnUndoAll', 'UpdateBanner', 'BtnUpdateNow', 'BtnUpdateLater', 'BtnCheckUpdate', 'UpdateInfo', 'TweakList', 'StatusText', 'ContentHost', 'BusyBar',
        'BtnCleanTemp', 'BtnCleanThumbs', 'BtnCleanUpdate', 'BtnCleanBin', 'BtnFlushDns', 'BtnCleanAll', 'BtnRestorePoint', 'BtnOpenRestore', 'BtnUndoAllRestore', 'RestoreList', 'BackupInfo',
        'ToggleCheckUpdates', 'ToggleRestoreBefore', 'BtnOpenData', 'BtnOpenLog', 'AboutVersion', 'StatRestore', 'LinkInstagram', 'LinkYouTube', 'LinkDiscord', 'LinkGitHub') +
        ('Home', 'Tweaks', 'Clean', 'Restore', 'Settings' | ForEach-Object { "Page$_"; "Nav$_" })) {
    Assert ($null -ne $window.FindName($n)) "Controle $n existe"
}

Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) { Write-Host "$script:Failures teste(s) falharam." -ForegroundColor Red; exit 1 }
Write-Host 'Todos os testes passaram.' -ForegroundColor Green
