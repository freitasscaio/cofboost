# Boost por jogo: detecção automática de jogos instalados + ajustes por executável.
#   - GPU de alto desempenho (útil em notebook com GPU integrada + dedicada)
#   - Prioridade de CPU alta sempre que o .exe abrir (Image File Execution Options)
#
# A detecção lê o que cada loja sabe que está instalado (Steam, Epic, Riot, EA, Ubisoft,
# GOG, Battle.net, Xbox) e escolhe o .exe do jogo dentro da pasta de instalação.

$script:Games = New-Object System.Collections.ArrayList

$script:GpuPrefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$script:IfeoKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

# Jogos cujo .exe certo não dá para adivinhar pela pasta, ou que ficam fora das lojas.
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

# .exe que nunca são o jogo: instaladores, anti-cheat, launchers, crash handlers, versões de teste.
$script:ExeSkip = '(?i)(unins|setup|install|redist|crash|launcher|anticheat|easyanticheat|eac_|beservice|battleye|' +
    'helper|report|updat|prereq|dxsetup|vc_?redist|dotnet|cefprocess|webhelper|_trial|showcase|benchmark|' +
    'dedicated|server|editor|touchup|cleanup|activation|register|elevate|socialclub|overlay|uploader|7za?$|python|' +
    'unitycrash|ue4prereq|vulkanrt|oalinst|physx|directx)'
# Pastas onde não há o jogo, só dependências.
$script:DirSkip = '(?i)^(redist|redistributables|_commonredist|commonredist|__installer|installer|installers|support|' +
    'directx|vcredist|dotnet|crashpad|crashreport\w*|prereq\w*|easyanticheat|battleye|eaanticheat|thirdparty|' +
    '__overlay|launcher|tools|docs|manual)$'
# Itens da Steam que não são jogos.
$script:SteamSkip = '(?i)(redistributable|steamworks|proton|steam linux runtime|steamvr|dedicated server|soundtrack|sdk)'

# ---------------------------------------------------------------- lista salva

function Get-GamesFile { Join-Path $script:Core.DataDir 'games.json' }
function Get-IgnoredGamesFile { Join-Path $script:Core.DataDir 'games-ignored.json' }

function Read-JsonList {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    # No PowerShell 5.1 o ConvertFrom-Json devolve o array inteiro como um objeto só,
    # por isso guardamos em variável antes de iterar.
    $data = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json
    @(foreach ($item in $data) { if ($null -ne $item) { $item } })
}

function Import-Games {
    $script:Games.Clear()
    foreach ($g in Read-JsonList (Get-GamesFile)) {
        if ($g.Path) { [void]$script:Games.Add([pscustomobject]@{ Name = $g.Name; Path = $g.Path }) }
    }
}

function Save-Games {
    ConvertTo-Json -InputObject @($script:Games) -Depth 3 | Set-Content -LiteralPath (Get-GamesFile) -Encoding UTF8
}

# Jogos que o usuário removeu: a detecção automática não os coloca de volta.
function Get-IgnoredGames { @(Read-JsonList (Get-IgnoredGamesFile)) }
function Set-IgnoredGames {
    param([string[]]$Paths)
    ConvertTo-Json -InputObject @($Paths | Sort-Object -Unique) | Set-Content -LiteralPath (Get-IgnoredGamesFile) -Encoding UTF8
}

function Add-Game {
    param([string]$Name, [string]$Path)
    if ($script:Games | Where-Object { $_.Path -eq $Path }) { return $false }
    [void]$script:Games.Add([pscustomobject]@{ Name = $Name; Path = $Path })
    Save-Games
    $ignored = Get-IgnoredGames
    if ($ignored -contains $Path) { Set-IgnoredGames @($ignored | Where-Object { $_ -ne $Path }) }
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
    Set-IgnoredGames (@(Get-IgnoredGames) + $Path)
    Write-Log "Jogo removido: $($g.Name)"
}

# Adiciona o que a detecção encontrou. -Automatic respeita os jogos que o usuário removeu.
function Add-DetectedGames {
    param($Found, [switch]$Automatic)
    $ignored = if ($Automatic) { Get-IgnoredGames } else { @() }
    $added = @()
    # A lista pode chegar embrulhada em outra (vinda de segundo plano): ForEach-Object desembrulha.
    foreach ($g in @($Found | ForEach-Object { $_ })) {
        if (-not $g -or $g.Path -isnot [string] -or $g.Name -isnot [string] -or $ignored -contains $g.Path) { continue }
        if (Add-Game $g.Name $g.Path) { $added += $g.Name }
    }
    $added
}

# ---------------------------------------------------------------- escolha do .exe

function Get-NormalizedName { param([string]$Text) ($Text -replace '[^\p{L}\p{Nd}]', '').ToLowerInvariant() }

function Get-CleanGameName { param([string]$Text) (($Text -replace '[™®©]', '') -replace '\s+', ' ').Trim() }

# .exe da pasta, até $MaxDepth níveis, sem entrar em pastas de dependências nem em junções.
function Get-ExeCandidates {
    param([string]$Dir, [int]$MaxDepth = 5)
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Dir, 0))
    while ($stack.Count) {
        $cur, $depth = $stack.Pop()
        try { $info = New-Object IO.DirectoryInfo $cur; $files = $info.GetFiles('*.exe'); $subs = $info.GetDirectories() } catch { continue }
        foreach ($f in $files) { [pscustomobject]@{ File = $f; Depth = $depth } }
        if ($depth -ge $MaxDepth) { continue }
        foreach ($s in $subs) {
            if ($s.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($s.Name -match $script:DirSkip) { continue }
            $stack.Push(@($s.FullName, ($depth + 1)))
        }
    }
}

# Nota cada .exe: nome parecido com o do jogo, executável final da Unreal (-Shipping),
# tamanho (o jogo costuma ser o maior) e profundidade. Devolve o melhor caminho ou $null.
function Find-GameExecutable {
    param([string]$Dir, [string]$Name, [string]$Hint)
    if (-not $Dir -or -not [IO.Directory]::Exists($Dir)) { return $null }
    $names = @((Get-NormalizedName $Name), (Get-NormalizedName (Split-Path $Dir -Leaf))) | Where-Object { $_.Length -ge 2 }
    $best = $null; $bestScore = [double]::MinValue
    foreach ($c in Get-ExeCandidates $Dir) {
        $f = $c.File
        if ($f.Length -lt 100KB -or $f.BaseName -match $script:ExeSkip) { continue }
        $base = Get-NormalizedName ($f.BaseName -replace '(?i)-win64-shipping$|-wingdk-shipping$|_x64$|64$', '')
        $score = [math]::Log($f.Length) - 0.5 * $c.Depth
        if ($base.Length -ge 2 -and ($names | Where-Object { $_.Contains($base) -or $base.Contains($_) })) { $score += 4 }
        if ($f.BaseName -match '(?i)shipping') { $score += 3 }
        if ($Hint -and $f.Name -eq (Split-Path $Hint -Leaf)) { $score += 1 }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $f.FullName }
    }
    $best
}

# ---------------------------------------------------------------- lojas

function Get-SteamLibraries {
    $roots = @()
    $steam = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    if ($steam) { $roots += ($steam.Value -replace '/', '\') }
    if (${env:ProgramFiles(x86)}) { $roots += Join-Path ${env:ProgramFiles(x86)} 'Steam' }
    $libs = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $libs += $r
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw -Encoding UTF8), '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    $libs | ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique
}

function Get-SteamGames {
    foreach ($lib in Get-SteamLibraries) {
        foreach ($acf in Get-ChildItem -LiteralPath (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $text = Get-Content -LiteralPath $acf.FullName -Raw -Encoding UTF8
            $name = [regex]::Match($text, '"name"\s+"([^"]+)"').Groups[1].Value
            $dir  = [regex]::Match($text, '"installdir"\s+"([^"]+)"').Groups[1].Value
            if (-not $name -or -not $dir -or $name -match $script:SteamSkip) { continue }
            $full = Join-Path $lib "steamapps\common\$dir"
            $known = $script:KnownGames | Where-Object { $_.Steam } | ForEach-Object {
                foreach ($rel in $_.Steam) { if ($rel -like "$dir\*") { Join-Path $lib "steamapps\common\$rel" } }
            } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            [pscustomobject]@{ Name = $name; Dir = $full; Exe = $known; Store = 'Steam' }
        }
    }
}

function Get-EpicGames {
    $dir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    foreach ($item in Get-ChildItem -LiteralPath $dir -Filter '*.item' -ErrorAction SilentlyContinue) {
        try { $j = Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($j.bIsIncompleteInstall) { continue }
        if ($j.AppCategories -and -not ($j.AppCategories -contains 'games')) { continue }
        [pscustomobject]@{ Name = $j.DisplayName; Dir = $j.InstallLocation; Hint = $j.LaunchExecutable; Store = 'Epic' }
    }
}

function Get-RiotGames {
    $meta = Join-Path $env:ProgramData 'Riot Games\Metadata'
    foreach ($f in Get-ChildItem -LiteralPath $meta -Recurse -Filter '*.product_settings.yaml' -ErrorAction SilentlyContinue) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        $m = [regex]::Match("$text", 'product_install_full_path:\s*"?([^"\r\n]+)"?')
        if (-not $m.Success) { continue }
        $product = ($f.Name -split '\.')[0]
        $name = switch -Regex ($product) { '^valorant' { 'Valorant' } '^league' { 'League of Legends' } '^bacon|^lor' { 'Legends of Runeterra' } '^riot_client' { $null } default { $product } }
        if ($name) { [pscustomobject]@{ Name = $name; Dir = ($m.Groups[1].Value -replace '/', '\'); Store = 'Riot' } }
    }
}

function Get-RegistryStoreGames {
    # GOG: exe e pasta direto no registro.
    foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games' -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p.gameName -and $p.path) { [pscustomobject]@{ Name = $p.gameName; Dir = $p.path; Exe = $(if ($p.exe -and (Test-Path -LiteralPath $p.exe) -and (Split-Path $p.exe -Leaf) -notmatch $script:ExeSkip) { $p.exe }); Store = 'GOG' } }
    }
    # Ubisoft Connect
    foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs' -ErrorAction SilentlyContinue) {
        $dir = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).InstallDir
        if ($dir) { [pscustomobject]@{ Name = (Split-Path ($dir -replace '/', '\').TrimEnd('\') -Leaf); Dir = ($dir -replace '/', '\'); Store = 'Ubisoft' } }
    }
    # EA app / Origin
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\EA Games', 'HKLM:\SOFTWARE\EA Games') {
        foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $dir = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).'Install Dir'
            if ($dir) { [pscustomobject]@{ Name = $k.PSChildName; Dir = $dir; Store = 'EA' } }
        }
    }
    # Battle.net (Blizzard) pelo registro de programas instalados
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p.Publisher -match 'Blizzard' -and $p.InstallLocation -and $p.DisplayName -notmatch 'Battle\.net') {
                [pscustomobject]@{ Name = $p.DisplayName; Dir = $p.InstallLocation; Store = 'Battle.net' }
            }
        }
    }
}

function Get-SearchRoots {
    $roots = @([System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        ForEach-Object { $_.RootDirectory.FullName })
    $roots += $env:ProgramFiles
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
    $roots | Sort-Object -Unique
}

function Get-XboxGames {
    foreach ($root in Get-SearchRoots) {
        foreach ($d in Get-ChildItem -LiteralPath (Join-Path $root 'XboxGames') -Directory -ErrorAction SilentlyContinue) {
            $content = Join-Path $d.FullName 'Content'
            [pscustomobject]@{ Name = $d.Name; Dir = $(if (Test-Path -LiteralPath $content) { $content } else { $d.FullName }); Store = 'Xbox' }
        }
    }
}

function Get-KnownGamePaths {
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
        if ($hit) { [pscustomobject]@{ Name = $g.Name; Path = $hit; Store = 'Conhecido' } }
    }
}

# Lista final: um item por .exe, com Name, Path e Store.
function Find-InstalledGames {
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    $sources = @(
        { Get-SteamGames }, { Get-EpicGames }, { Get-RiotGames }, { Get-RegistryStoreGames }, { Get-XboxGames }
    )
    foreach ($src in $sources) {
        foreach ($g in @(try { & $src } catch { Write-Log "Detecção: $($_.Exception.Message)" 'WARN' })) {
            if (-not $g -or -not $g.Name) { continue }
            $exe = if ($g.Exe) { $g.Exe } else { Find-GameExecutable -Dir $g.Dir -Name $g.Name -Hint $g.Hint }
            if (-not $exe -or $seen.ContainsKey($exe.ToLower())) { continue }
            $seen[$exe.ToLower()] = $true
            [void]$out.Add([pscustomobject]@{ Name = (Get-CleanGameName $g.Name); Path = $exe; Store = $g.Store })
        }
    }
    foreach ($g in @(Get-KnownGamePaths)) {
        if ($seen.ContainsKey($g.Path.ToLower())) { continue }
        $seen[$g.Path.ToLower()] = $true
        [void]$out.Add($g)
    }
    $out
}

# ---------------------------------------------------------------- boost

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
