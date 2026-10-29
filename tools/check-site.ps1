<#
.SYNOPSIS
    Confere o site antes de publicar: campos pendentes nos documentos legais e
    recursos de terceiros carregados automaticamente (que enviariam o IP do visitante).
    Uso: powershell -ExecutionPolicy Bypass -File tools\check-site.ps1
    Sai com código 1 se encontrar algum problema.
#>
$site = Join-Path (Split-Path $PSScriptRoot -Parent) 'site'
$problems = @()
foreach ($f in Get-ChildItem -LiteralPath $site -Filter *.html) {
    $t = [IO.File]::ReadAllText($f.FullName)
    foreach ($m in [regex]::Matches($t, '<mark class="todo">([^<]+)</mark>')) { $problems += "$($f.Name): campo pendente $($m.Groups[1].Value)" }
    # Só links (<a href>) podem apontar para fora; scripts, estilos, fontes, imagens e iframes, não.
    foreach ($m in [regex]::Matches($t, '<(script|link|img|iframe|source|video|audio)\b[^>]*\b(src|href)="(https?:)?//[^"]+"', 'IgnoreCase')) { $problems += "$($f.Name): recurso externo carregado automaticamente: $($m.Value)" }
    # Rastreamento e armazenamento: procura só dentro dos scripts (o texto da política cita esses nomes).
    $scripts = -join ([regex]::Matches($t, '(?is)<script\b[^>]*>(.*?)</script>') | ForEach-Object { $_.Groups[1].Value })
    foreach ($k in 'googletagmanager', 'google-analytics', 'gtag(', 'fbq(', 'document.cookie', 'localStorage', 'sessionStorage') {
        if ($scripts.Contains($k)) { $problems += "$($f.Name): '$k' encontrado: rever a Política de Privacidade e o consentimento" }
    }
}
# Google Analytics só via assets/consent.js (que carrega depois do aceite), com o mesmo ID em
# todas as páginas e a Política descrevendo o uso.
$ids = @(Get-ChildItem -LiteralPath $site -Filter *.html | ForEach-Object {
    $m = [regex]::Match([IO.File]::ReadAllText($_.FullName), '<script src="assets/consent\.js" data-ga-id="([^"]*)"')
    if (-not $m.Success) { $problems += "$($_.Name): sem o script de consentimento (assets/consent.js)"; $null } else { $m.Groups[1].Value }
}) | Sort-Object -Unique
if (@($ids).Count -gt 1) { $problems += "IDs do Google Analytics diferentes entre as páginas: $($ids -join ', ')" }
$gaId = @($ids)[0]
if ($gaId -and $gaId -notmatch '^G-[A-Z0-9]{4,16}$') { $problems += "ID do Google Analytics inválido: '$gaId' (formato G-XXXXXXXXXX)" }
if ($gaId -and -not ([IO.File]::ReadAllText((Join-Path $site 'privacidade.html'))).Contains('id="analytics"')) { $problems += 'Analytics ativo, mas a Política de Privacidade não tem a seção do Google Analytics' }
Write-Host $(if ($gaId) { "Google Analytics ATIVO ($gaId), só depois do consentimento." } else { 'Google Analytics desligado (data-ga-id vazio): sem banner e sem cookies.' })

if ($problems) { $problems | ForEach-Object { Write-Host "  PENDENTE $_" -ForegroundColor Yellow }; exit 1 }
Write-Host 'Site pronto para publicar: sem pendências nem recursos de terceiros.' -ForegroundColor Green
