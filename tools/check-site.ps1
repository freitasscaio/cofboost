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
if ($problems) { $problems | ForEach-Object { Write-Host "  PENDENTE $_" -ForegroundColor Yellow }; exit 1 }
Write-Host 'Site pronto para publicar: sem pendências nem recursos de terceiros.' -ForegroundColor Green
