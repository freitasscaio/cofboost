# Núcleo do Overclutch: log, backup e escrita rastreada no registro.
# Toda alteração feita por um ajuste é gravada em backup.json ANTES de ser aplicada,
# para que possa ser desfeita exatamente como estava.

$script:AppName    = 'Overclutch'
$script:AppVersion = '1.0.2'

$script:Core = @{
    DataDir    = $null
    BackupFile = $null
    LogFile    = $null
    DryRun     = $false
    Backup     = @{}
    OnLog      = $null
}

function Initialize-Core {
    param(
        [string]$DataDir = (Join-Path $env:ProgramData $script:AppName),
        [switch]$DryRun
    )
    $script:Core.DataDir    = $DataDir
    $script:Core.BackupFile = Join-Path $DataDir 'backup.json'
    $script:Core.LogFile    = Join-Path $DataDir 'overclutch.log'
    $script:Core.DryRun     = [bool]$DryRun
    if (-not (Test-Path -LiteralPath $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        if ($DataDir -eq (Join-Path $env:ProgramData $script:AppName)) { Import-LegacyData $DataDir }
    }
    $script:Core.Backup = Read-Backup
}

# O app se chamava NitroFPS: traz backup, jogos e log da pasta antiga para o
# "Desfazer" continuar valendo para o que já foi aplicado.
function Import-LegacyData {
    param([string]$DataDir)
    $legacy = Join-Path $env:ProgramData 'NitroFPS'
    if (-not (Test-Path -LiteralPath (Join-Path $legacy 'backup.json'))) { return }
    foreach ($pair in @(@('backup.json', 'backup.json'), @('games.json', 'games.json'), @('nitrofps.log', 'overclutch.log'))) {
        $from = Join-Path $legacy $pair[0]
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $DataDir $pair[1]) -Force }
    }
    Write-Log "Dados migrados de $legacy (versão NitroFPS)."
}

function Test-DryRun { [bool]$script:Core.DryRun }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    try { Add-Content -LiteralPath $script:Core.LogFile -Value $line -Encoding UTF8 } catch { }
    if ($script:Core.OnLog) { & $script:Core.OnLog $line }
}

# ---------------------------------------------------------------- backup

function Read-Backup {
    $result = @{}
    if (Test-Path -LiteralPath $script:Core.BackupFile) {
        $json = Get-Content -LiteralPath $script:Core.BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json) {
            foreach ($prop in $json.PSObject.Properties) {
                $list = New-Object System.Collections.ArrayList
                foreach ($e in @($prop.Value)) { [void]$list.Add($e) }
                $result[$prop.Name] = $list
            }
        }
    }
    $result
}

function Save-Backup {
    if (Test-DryRun) { return }
    $out = @{}
    foreach ($k in $script:Core.Backup.Keys) {
        $v = @($script:Core.Backup[$k])
        if ($v.Count) { $out[$k] = $v }
    }
    $tmp = "$($script:Core.BackupFile).tmp"
    ConvertTo-Json -InputObject $out -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:Core.BackupFile -Force
}

function Get-BackupEntries {
    param([string]$TweakId)
    if ($script:Core.Backup.ContainsKey($TweakId)) { return @($script:Core.Backup[$TweakId]) }
    return @()
}

function Add-BackupEntry {
    param([string]$TweakId, $Entry)
    if (-not $script:Core.Backup.ContainsKey($TweakId)) {
        $script:Core.Backup[$TweakId] = New-Object System.Collections.ArrayList
    }
    [void]$script:Core.Backup[$TweakId].Add($Entry)
    Save-Backup
}

function Get-BackedUpIds { @($script:Core.Backup.Keys) }

# ---------------------------------------------------------------- registro

function Split-RegPath {
    param([string]$Path)
    if ($Path -notmatch '^(HKLM|HKCU):\\(.+)$') { throw "Caminho de registro inválido: $Path" }
    $hive = if ($Matches[1] -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    @($hive, $Matches[2])
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    $hive, $sub = Split-RegPath $Path
    $key = $hive.OpenSubKey($sub, $false)
    if (-not $key) { return $null }
    try {
        if ($key.GetValueNames() -notcontains $Name) { return $null }
        [pscustomobject]@{
            Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Type  = $key.GetValueKind($Name).ToString()
        }
    } finally { $key.Close() }
}

function Set-RegValueRaw {
    param([string]$Path, [string]$Name, $Value, [string]$Type)
    $hive, $sub = Split-RegPath $Path
    $kind = [Microsoft.Win32.RegistryValueKind]$Type
    switch ($kind) {
        'Binary'      { $Value = [byte[]]$Value }
        'MultiString' { $Value = [string[]]$Value }
        'DWord'       { $Value = [int]$Value }
        'QWord'       { $Value = [long]$Value }
        default       { $Value = [string]$Value }
    }
    # CreateSubKey abre a chave se ela já existe (não apaga nada) ou cria se não existe.
    $key = $hive.CreateSubKey($sub)
    try { $key.SetValue($Name, $Value, $kind) } finally { $key.Close() }
}

function Remove-RegValueRaw {
    param([string]$Path, [string]$Name)
    $hive, $sub = Split-RegPath $Path
    $key = $hive.OpenSubKey($sub, $true)
    if ($key) { try { $key.DeleteValue($Name, $false) } finally { $key.Close() } }
}

# Grava um valor no registro guardando o valor original no backup do ajuste.
function Set-TrackedRegistry {
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    if (Test-DryRun) {
        Write-Log "[SIMULAÇÃO] $Path\$Name = $Value ($Type)"
        return
    }
    $already = Get-BackupEntries $TweakId | Where-Object { $_.Kind -eq 'Reg' -and $_.Path -eq $Path -and $_.Name -eq $Name }
    if (-not $already) {
        $cur = Get-RegValue $Path $Name
        Add-BackupEntry $TweakId ([pscustomobject]@{
            Kind    = 'Reg'
            Path    = $Path
            Name    = $Name
            Existed = [bool]$cur
            Value   = $(if ($cur) { $cur.Value } else { $null })
            Type    = $(if ($cur) { $cur.Type } else { $Type })
        })
    }
    Set-RegValueRaw $Path $Name $Value $Type
    Write-Log "$Path\$Name = $Value"
}

function Disable-TrackedService {
    param([string]$TweakId, [string]$Service)
    if (-not (Get-Service -Name $Service -ErrorAction SilentlyContinue)) {
        Write-Log "Serviço $Service não existe neste PC, ignorando."
        return
    }
    Set-TrackedRegistry -TweakId $TweakId -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Service" -Name 'Start' -Value 4
    if (-not (Test-DryRun)) { Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue }
}

# Desfaz tudo que foi gravado para um ajuste, na ordem inversa.
function Restore-Backup {
    param([string]$TweakId)
    $entries = @(Get-BackupEntries $TweakId)
    if ($entries.Count -eq 0) { return }
    [array]::Reverse($entries)
    $failed = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        if (Test-DryRun) {
            Write-Log "[SIMULAÇÃO] Reverter $($e.Kind) $($e.Path)\$($e.Name)"
            continue
        }
        try {
            if ($e.Kind -eq 'Reg') {
                if ($e.Existed) { Set-RegValueRaw $e.Path $e.Name $e.Value $e.Type }
                else { Remove-RegValueRaw $e.Path $e.Name }
                Write-Log "Revertido $($e.Path)\$($e.Name)"
            } elseif ($e.Kind -eq 'PowerPlan') {
                powercfg /setactive $e.Previous | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive $($e.Previous) falhou" }
                if ($e.Created) { powercfg /delete $e.Created | Out-Null }
                Write-Log "Plano de energia anterior restaurado ($($e.Previous))"
            }
        } catch {
            Write-Log "Falha ao reverter $($e.Kind) $($e.Path)\$($e.Name): $($_.Exception.Message)" 'ERROR'
            [void]$failed.Add($e)
        }
    }
    if (Test-DryRun) { return }
    if ($failed.Count) {
        $failed.Reverse()
        $script:Core.Backup[$TweakId] = $failed
    } else {
        [void]$script:Core.Backup.Remove($TweakId)
    }
    Save-Backup
}

# ---------------------------------------------------------------- utilidades

function New-RestorePoint {
    if (Test-DryRun) { Write-Log '[SIMULAÇÃO] Criar ponto de restauração'; return $true }
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "$($script:AppName) - antes da otimização" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
        Write-Log 'Ponto de restauração criado.'
        $true
    } catch {
        Write-Log "Não foi possível criar ponto de restauração: $($_.Exception.Message)" 'WARN'
        $false
    }
}

# Usa .NET direto em vez de Remove-Item: o Remove-Item pede confirmação ao apagar pasta
# que ainda tem arquivo em uso, e com o console escondido isso travava o app para sempre.
function Clear-TempFiles {
    param(
        [string[]]$Paths = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')),
        [hashtable]$Progress = @{}
    )
    $freed = [long]0; $files = 0; $skipped = 0
    foreach ($dir in $Paths) {
        # Proteção: nunca limpar raiz de disco ou caminho vazio.
        if (-not $dir -or $dir.Length -le 3 -or -not [IO.Directory]::Exists($dir)) { continue }
        $stack = New-Object System.Collections.Stack
        $subdirs = New-Object System.Collections.Generic.List[string]
        $stack.Push($dir)
        while ($stack.Count) {
            $cur = $stack.Pop()
            try { $entries = (New-Object IO.DirectoryInfo $cur).GetFileSystemInfos() } catch { continue }
            foreach ($e in $entries) {
                # Nunca entra em atalhos/junções: poderiam apontar para fora da pasta TEMP.
                if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName); $subdirs.Add($e.FullName); continue }
                $len = $e.Length
                if (Test-DryRun) { $freed += $len; $files++ }
                else {
                    try {
                        if ($e.IsReadOnly) { $e.IsReadOnly = $false }
                        $e.Delete(); $freed += $len; $files++
                    } catch { $skipped++ }
                }
                $Progress.Files = $files
            }
        }
        if (-not (Test-DryRun)) {
            # Subpastas da mais funda para a mais rasa; pasta com arquivo em uso simplesmente fica.
            for ($i = $subdirs.Count - 1; $i -ge 0; $i--) {
                try { [IO.Directory]::Delete($subdirs[$i], $false) } catch { }
            }
        }
    }
    [pscustomobject]@{ MB = [math]::Round($freed / 1MB, 1); Bytes = $freed; Files = $files; Skipped = $skipped }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f [math]::Ceiling($Bytes / 1KB)
}

function Clear-Dns {
    if (Test-DryRun) { Write-Log '[SIMULAÇÃO] Limpar cache DNS'; return }
    try { Clear-DnsClientCache -ErrorAction Stop } catch { ipconfig /flushdns | Out-Null }
    Write-Log 'Cache DNS limpo.'
}

function Get-SystemInfo {
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $gpu = (Get-CimInstance Win32_VideoController |
        Where-Object { $_.Name -notmatch 'Basic|Virtual|Parsec|Remote' } |
        ForEach-Object { $_.Name }) -join ' + '
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $os  = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        Cpu = "$cpu".Trim()
        Gpu = $(if ($gpu) { $gpu } else { 'Não identificada' })
        Ram = "$ram GB"
        Os  = "$($os.Caption) (build $($os.BuildNumber))"
    }
}
