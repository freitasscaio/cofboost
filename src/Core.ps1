# Núcleo do CofBoost: log, backup e escrita rastreada no registro.
# Toda alteração feita por um ajuste é gravada em backup.json ANTES de ser aplicada,
# para que possa ser desfeita exatamente como estava.

$script:AppName    = 'CofBoost'
$script:AppVersion = '1.1.0'

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
    $script:Core.LogFile    = Join-Path $DataDir 'cofboost.log'
    $script:Core.DryRun     = [bool]$DryRun
    if (-not (Test-Path -LiteralPath $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        if ($DataDir -eq (Join-Path $env:ProgramData $script:AppName)) { Import-LegacyData $DataDir }
    }
    $script:Core.Backup = Read-Backup
}

# O app já se chamou Overclutch e, antes, NitroFPS: traz backup, configurações e log da
# pasta antiga mais recente para o "Desfazer" continuar valendo para o que já foi aplicado.
function Import-LegacyData {
    param([string]$DataDir)
    foreach ($old in @(@('Overclutch', 'overclutch.log'), @('NitroFPS', 'nitrofps.log'))) {
        $legacy = Join-Path $env:ProgramData $old[0]
        if (-not (Test-Path -LiteralPath (Join-Path $legacy 'backup.json'))) { continue }
        foreach ($pair in @(@('backup.json', 'backup.json'), @('settings.json', 'settings.json'), @($old[1], 'cofboost.log'))) {
            $from = Join-Path $legacy $pair[0]
            if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $DataDir $pair[1]) -Force }
        }
        Write-Log "Dados migrados de $legacy (versão $($old[0]))."
        return
    }
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

# Cache de miniaturas e ícones do Explorer. Os arquivos em uso pelo Explorer ficam;
# o Windows recria o cache sozinho.
function Clear-ThumbnailCache {
    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    $freed = [long]0; $files = 0; $skipped = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' })) {
        if (Test-DryRun) { $freed += $f.Length; $files++; continue }
        try { $len = $f.Length; $f.Delete(); $freed += $len; $files++ } catch { $skipped++ }
    }
    [pscustomobject]@{ MB = [math]::Round($freed / 1MB, 1); Bytes = $freed; Files = $files; Skipped = $skipped }
}

# Atualizações do Windows já baixadas e instaladas. O Windows baixa de novo se precisar.
function Clear-WindowsUpdateCache {
    Clear-TempFiles -Paths @(Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
}

function Get-RecycleBinInfo {
    $count = 0; $bytes = [long]0
    try {
        $bin = (New-Object -ComObject Shell.Application).Namespace(10)
        foreach ($item in @($bin.Items())) { $count++; try { $bytes += [long]$item.Size } catch { } }
    } catch { }
    [pscustomobject]@{ Files = $count; Bytes = $bytes; MB = [math]::Round($bytes / 1MB, 1); Skipped = 0 }
}

function Clear-RecycleBinSafe {
    $info = Get-RecycleBinInfo
    if (-not (Test-DryRun) -and $info.Files) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
    $info
}

# Pontos de restauração do Windows, do mais novo para o mais antigo.
function Get-RestorePoints {
    try {
        @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending | ForEach-Object {
            [pscustomobject]@{
                Description = "$($_.Description)"
                Date = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime)
                Number = $_.SequenceNumber
            }
        })
    } catch { @() }
}

# ---------------------------------------------------------------- configurações

$script:DefaultSettings = @{ CheckUpdates = $true; RestorePointBeforeBoost = $true }

function Get-SettingsFile { Join-Path $script:Core.DataDir 'settings.json' }

function Get-Setting {
    param([string]$Name)
    $file = Get-SettingsFile
    if (Test-Path -LiteralPath $file) {
        try {
            $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data.PSObject.Properties[$Name]) { return $data.$Name }
        } catch { }
    }
    $script:DefaultSettings[$Name]
}

function Set-Setting {
    param([string]$Name, $Value)
    $all = @{}
    $file = Get-SettingsFile
    if (Test-Path -LiteralPath $file) {
        try { (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $all[$_.Name] = $_.Value } } catch { }
    }
    $all[$Name] = $Value
    ConvertTo-Json -InputObject $all | Set-Content -LiteralPath $file -Encoding UTF8
}

# Links do rodapé do menu. Link vazio = ícone escondido.
$script:Links = [ordered]@{
    Instagram = ''
    YouTube   = ''
    Discord   = ''
    GitHub    = 'https://github.com/freitasscaio/overclutch'
}
function Clear-Dns {
    if (Test-DryRun) { Write-Log '[SIMULAÇÃO] Limpar cache DNS'; return }
    try { Clear-DnsClientCache -ErrorAction Stop } catch { ipconfig /flushdns | Out-Null }
    Write-Log 'Cache DNS limpo.'
}

# Dados para o Painel. Cada parte tem fallback: um item que falhar não derruba os outros.
function Get-SystemInfo {
    $info = [ordered]@{
        Cpu = 'Não identificado'; CpuChip = ''; CpuThreads = ''; Gpu = 'Não identificada'; GpuChip = ''
        Ram = ''; RamChip = ''; Disk = ''; DiskChip = ''
        Os = ''; OsVersion = ''; OsBuild = ''; DiskModel = ''
    }
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $info.Cpu = ("$($cpu.Name)" -replace '\s+', ' ' -replace '\s*\d+-Core Processor', '').Trim()
        $info.CpuChip = "$($cpu.NumberOfCores) núcleos"
        $info.CpuThreads = "$($cpu.NumberOfCores) núcleos e $($cpu.NumberOfLogicalProcessors) threads"
    } catch { }
    try {
        $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Parsec|Remote' } | Select-Object -First 1
        if ($gpu) {
            $info.Gpu = ("$($gpu.Name)" -replace '^(NVIDIA|AMD|Intel\(R\)|Intel)\s+', '').Trim()   # o fabricante já aparece no modelo (GeForce, Radeon, Arc)
            # Win32_VideoController limita a 4 GB; o tamanho real fica no registro do driver.
            $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
            $vram = Get-ChildItem $cls -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
                Where-Object { $_.DriverDesc -eq $gpu.Name -and $_.'HardwareInformation.qwMemorySize' } | Select-Object -First 1
            if ($vram) { $info.GpuChip = '{0:N0} GB' -f ($vram.'HardwareInformation.qwMemorySize' / 1GB) }
        }
    } catch { }
    try {
        $mem = @(Get-CimInstance Win32_PhysicalMemory)
        $total = ($mem | Measure-Object Capacity -Sum).Sum
        if (-not $total) { $total = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory }
        $info.Ram = '{0:N0} GB' -f ($total / 1GB)
        $type = switch (($mem | Select-Object -First 1).SMBIOSMemoryType) { 20 { 'DDR' } 21 { 'DDR2' } 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } default { '' } }
        $speed = ($mem | Select-Object -First 1).ConfiguredClockSpeed
        $info.RamChip = (@($type, $(if ($speed) { "$speed MT/s" })) | Where-Object { $_ }) -join ' '
    } catch { }
    try {
        $part = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" } | Select-Object -First 1
        if ($pd) {
            $info.Disk = '{0:N0} GB' -f ($pd.Size / 1GB)
            $media = switch ("$($pd.MediaType)") { 'SSD' { 'SSD' } 'HDD' { 'HD' } default { '' } }
            $info.DiskChip = (@($media, $(if ("$($pd.BusType)" -eq 'NVMe') { 'NVMe' })) | Where-Object { $_ }) -join ' '
            $info.DiskModel = "$($pd.FriendlyName)".Trim()
        }
    } catch {
        try { $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"; $info.Disk = '{0:N0} GB' -f ($d.Size / 1GB) } catch { }
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $info.Os = ("$($os.Caption)" -replace '^Microsoft\s+', '').Trim()
        $info.OsVersion = "$($cv.DisplayVersion)"
        $info.OsBuild = $(if ($cv.UBR) { "$($cv.CurrentBuild).$($cv.UBR)" } else { "$($os.BuildNumber)" })
    } catch { }
    [pscustomobject]$info
}
