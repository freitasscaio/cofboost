# Atualização pelo GitHub Releases: consulta a versão mais recente, baixa o instalador
# oficial, confere o SHA-256 publicado pelo GitHub e roda a instalação.
# Usa só Write-Log do Core, para poder rodar também em segundo plano (Invoke-InBackground).

$script:UpdateRepo  = 'freitasscaio/cofboost'
$script:UpdateAsset = 'CofBoost-Setup.exe'

function Enable-Tls12 {
    # O PowerShell 5.1 nem sempre liga o TLS 1.2, que o GitHub exige.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Só aceita dados no formato esperado: evita baixar de outro lugar ou montar comandos com lixo.
function Test-ReleaseInfo {
    param($Release)
    if (-not $Release) { return $false }
    $urlPattern = '^https://github\.com/' + [regex]::Escape($script:UpdateRepo) + '/releases/download/v[0-9.]+/' + [regex]::Escape($script:UpdateAsset) + '$'
    ($Release.Version -match '^\d+(\.\d+){1,3}$') -and
        ($Release.Url -match $urlPattern) -and
        (-not $Release.Sha256 -or $Release.Sha256 -match '^[0-9a-f]{64}$')
}

function Get-LatestRelease {
    Enable-Tls12
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:UpdateRepo)/releases/latest" `
        -Headers @{ 'User-Agent' = 'CofBoost'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 15
    $asset = $rel.assets | Where-Object { $_.name -eq $script:UpdateAsset } | Select-Object -First 1
    $sha = $null
    if ($asset -and $asset.PSObject.Properties['digest'] -and "$($asset.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1].ToLower() }
    $info = [pscustomobject]@{
        Version = "$($rel.tag_name)" -replace '^v', ''
        Url     = $(if ($asset) { "$($asset.browser_download_url)" } else { $null })
        Size    = $(if ($asset) { [long]$asset.size } else { 0 })
        Sha256  = $sha
        Page    = "$($rel.html_url)"
    }
    # Release sem o instalador esperado (ainda sendo publicada, ou de quando o app tinha
    # outro nome): não é erro. Quem chama confere Test-ReleaseInfo antes de oferecer.
    $info | Add-Member -NotePropertyName Installable -NotePropertyValue ([bool](Test-ReleaseInfo $info))
    $info
}

function Test-NewerVersion {
    param([string]$Latest, [string]$Current)
    try { [version]$Latest -gt [version]$Current } catch { $false }
}

function Save-UpdateInstaller {
    param($Release)
    if (-not (Test-ReleaseInfo $Release)) { throw 'Dados da atualização inválidos.' }
    Enable-Tls12
    $dir = Join-Path $env:TEMP 'CofBoost-Update'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir "CofBoost-Setup-$($Release.Version).exe"
    Write-Log "Baixando atualização $($Release.Version)..."
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'CofBoost')
    try { $wc.DownloadFile($Release.Url, $file) } finally { $wc.Dispose() }

    $size = (Get-Item -LiteralPath $file).Length
    if ($Release.Size -and $size -ne $Release.Size) {
        Remove-Item -LiteralPath $file -Force
        throw "Download incompleto ($size de $($Release.Size) bytes)."
    }
    if ($Release.Sha256) {
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $Release.Sha256) {
            Remove-Item -LiteralPath $file -Force
            throw 'O arquivo baixado não confere com o publicado no GitHub (SHA-256 diferente).'
        }
        Write-Log "Atualização baixada e conferida (SHA-256 $hash)."
    } else {
        Write-Log 'Atualização baixada (o GitHub não informou SHA-256 para conferir).' 'WARN'
    }
    $file
}

# /SILENT mostra só a barra de progresso; /UPDATE=1 faz o instalador reabrir o app no fim.
function Start-UpdateInstaller {
    param([string]$Path)
    Write-Log "Iniciando instalador da atualização: $Path"
    Start-Process -FilePath $Path -ArgumentList '/SILENT', '/NORESTART', '/UPDATE=1'
}
