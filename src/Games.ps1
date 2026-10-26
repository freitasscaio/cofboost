# Boost por jogo: detecção automática de jogos instalados + ajustes por executável.
#   - GPU de alto desempenho (útil em notebook com GPU integrada + dedicada)
#   - Prioridade de CPU alta sempre que o .exe abrir (Image File Execution Options)

$script:Games = New-Object System.Collections.ArrayList

$script:GpuPrefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$script:IfeoKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

# Steam = caminho relativo a steamapps\common; Roots = relativo à raiz dos discos / Program Files.
$script:KnownGames = @(
    @{ Name = 'Counter-Strike 2';    Steam = @('Counter-Strike Global Offensive\game\bin\win64\cs2.exe') }
    @{ Name = 'Dota 2';              Steam = @('dota 2 beta\game\bin\win64\dota2.exe') }
    @{ Name = 'Rocket League';       Steam = @('rocketleague\Binaries\Win64\RocketLeague.exe'); Roots = @('Epic Games\rocketleague\Binaries\Win64\RocketLeague.exe') }
    @{ Name = 'Valorant';            Roots = @('Riot Games\VALORANT\live\ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe') }
    @{ Name = 'League of Legends';   Roots = @('Riot Games\League of Legends\Game\League of Legends.exe') }
    @{ Name = 'Fortnite';            Roots = @('Epic Games\Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe') }
    @{ Name = 'Apex Legends';        Steam = @('Apex Legends\r5apex_dx12.exe', 'Apex Legends\r5apex.exe') }
    @{ Name = 'PUBG: Battlegrounds'; Steam = @('PUBG\TslGame\Binaries\Win64\TslGame.exe') }
    @{ Name = 'Rainbow Six Siege';   Steam = @("Tom Clancy's Rainbow Six Siege\RainbowSix.exe") }
    @{ Name = 'GTA V';               Steam = @('Grand Theft Auto V\GTA5.exe') }
    @{ Name = 'Roblox';              Glob  = "$env:LOCALAPPDATA\Roblox\Versions\*\RobloxPlayerBeta.exe" }
)

function Get-GamesFile { Join-Path $script:Core.DataDir 'games.json' }

function Import-Games {
    $script:Games.Clear()
    $file = Get-GamesFile
    if (Test-Path -LiteralPath $file) {
        # No PowerShell 5.1 o ConvertFrom-Json devolve o array inteiro como um objeto só,
        # por isso guardamos em variável antes de iterar.
        $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($g in $data) {
            if ($g -and $g.Path) { [void]$script:Games.Add([pscustomobject]@{ Name = $g.Name; Path = $g.Path }) }
        }
    }
}

function Save-Games {
    ConvertTo-Json -InputObject @($script:Games) -Depth 3 | Set-Content -LiteralPath (Get-GamesFile) -Encoding UTF8
}

function Add-Game {
    param([string]$Name, [string]$Path)
    if ($script:Games | Where-Object { $_.Path -eq $Path }) { return $false }
    [void]$script:Games.Add([pscustomobject]@{ Name = $Name; Path = $Path })
    Save-Games
    Write-Log "Jogo adicionado: $Name ($Path)"
    $true
}

function Remove-Game {
    param([string]$Path)
    $g = $script:Games | Where-Object { $_.Path -eq $Path } | Select-Object -First 1
    if (-not $g) { return }
    Undo-GameBoost $g
    $script:Games.Remove($g)
    Save-Games
    Write-Log "Jogo removido: $($g.Name)"
}

function Get-SteamLibraries {
    $roots = @()
    $steam = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    if ($steam) { $roots += ($steam.Value -replace '/', '\') }
    $roots += Join-Path ${env:ProgramFiles(x86)} 'Steam'
    $libs = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $libs += $r
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    $libs | Sort-Object -Unique
}

function Get-SearchRoots {
    $roots = @([System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        ForEach-Object { $_.RootDirectory.FullName })
    $roots += $env:ProgramFiles
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
    $roots | Sort-Object -Unique
}

function Find-InstalledGames {
    $found = @()
    $steamLibs = @(Get-SteamLibraries)
    $roots = @(Get-SearchRoots)
    foreach ($g in $script:KnownGames) {
        $candidates = @()
        foreach ($rel in $g.Steam) { foreach ($lib in $steamLibs) { $candidates += Join-Path $lib "steamapps\common\$rel" } }
        foreach ($rel in $g.Roots) { foreach ($root in $roots) { $candidates += Join-Path $root $rel } }
        $hit = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $hit -and $g.Glob) {
            $hit = Get-ChildItem -Path $g.Glob -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($hit) { $found += [pscustomobject]@{ Name = $g.Name; Path = $hit } }
    }
    $found
}

function Get-GameTweakId { param($Game) "game:$($Game.Path.ToLower())" }

function Test-GameBoosted {
    param($Game)
    $cur = Get-RegValue $script:GpuPrefKey $Game.Path
    [bool]($cur -and $cur.Value -eq 'GpuPreference=2;')
}

function Invoke-GameBoost {
    param($Game)
    $id  = Get-GameTweakId $Game
    $exe = Split-Path $Game.Path -Leaf
    Write-Log "Boost no jogo: $($Game.Name)"
    Set-TrackedRegistry -TweakId $id -Path $script:GpuPrefKey -Name $Game.Path -Value 'GpuPreference=2;' -Type 'String'
    Set-TrackedRegistry -TweakId $id -Path "$($script:IfeoKey)\$exe\PerfOptions" -Name 'CpuPriorityClass' -Value 3
}

function Undo-GameBoost {
    param($Game)
    Write-Log "Removendo boost: $($Game.Name)"
    Restore-Backup (Get-GameTweakId $Game)
}
