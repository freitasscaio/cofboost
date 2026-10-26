# Catálogo de otimizações. Cada ajuste é um hashtable:
#   Id, Category, Name, Description, Default (entra no "Otimizar agora"), Reboot, Risk
#   Registry = lista de @{ Path; Name; Value; Type }   -> aplicado e verificado automaticamente
#   Services = lista de nomes de serviço para desativar -> idem
#   Apply / Test = scriptblocks opcionais para casos especiais
# Para reverter, sempre usamos o backup gravado pelo Core (nada é "chutado").

function RegSet {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    @{ Path = $Path; Name = $Name; Value = $Value; Type = $Type }
}

$script:MMCSS       = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$script:TcpIfaces   = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$script:UltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

function Get-ActiveSchemeGuid {
    $out = (powercfg /getactivescheme) -join ' '
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1].ToLower() }
    $null
}

# Só placas físicas conectadas: adaptadores virtuais (Hyper-V, VPN, Tailscale) não
# importam para o ping do jogo, e o "Default Switch" do Hyper-V muda de GUID a cada boot.
function Get-ActiveTcpInterfaces {
    foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) {
        $path = "$($script:TcpIfaces)\$($a.InterfaceGuid.ToLower())"
        $hive, $sub = Split-RegPath $path
        $key = $hive.OpenSubKey($sub)
        if ($key) { $key.Close(); $path }
    }
}

$script:Tweaks = @(
    # ------------------------------------------------------------ Sistema
    @{
        Id = 'power-plan'; Category = 'Sistema'; Default = $true; Risk = 'Baixo'
        Name = 'Plano de energia Desempenho Máximo'
        Description = 'Ativa o plano "Desempenho Máximo" (ou Alto Desempenho) para o CPU não reduzir clock no meio do jogo. Em notebook, consome mais bateria.'
        Apply = {
            param($t)
            $previous = Get-ActiveSchemeGuid
            if (-not $previous) { throw 'Não foi possível ler o plano de energia atual.' }
            if (Test-DryRun) { Write-Log '[SIMULAÇÃO] Ativar plano Desempenho Máximo'; return }
            $entry = Get-BackupEntries $t.Id | Where-Object { $_.Kind -eq 'PowerPlan' } | Select-Object -First 1
            $target = $null
            if ($entry -and -not $entry.Created) { $target = $script:HighPerfGuid }
            elseif ($entry -and ((powercfg /list) -join ' ') -match $entry.Created) { $target = $entry.Created }
            if (-not $target) {
                $created = $null
                $out = (powercfg /duplicatescheme $script:UltimateGuid) -join ' '
                if ($LASTEXITCODE -eq 0 -and $out -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { $created = $Matches[1].ToLower() }
                $target = if ($created) { $created } else { $script:HighPerfGuid }
                if (-not $entry) {
                    Add-BackupEntry $t.Id ([pscustomobject]@{ Kind = 'PowerPlan'; Previous = $previous; Created = $created })
                }
            }
            powercfg /setactive $target | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Falha ao ativar o plano $target" }
            Write-Log "Plano de energia ativo: $target"
        }
        Test = {
            $active = Get-ActiveSchemeGuid
            $entry = Get-BackupEntries 'power-plan' | Where-Object { $_.Kind -eq 'PowerPlan' } | Select-Object -First 1
            ($entry -and $entry.Created -and $active -eq $entry.Created) -or
                $active -eq $script:HighPerfGuid -or $active -eq $script:UltimateGuid
        }
    }
    @{
        Id = 'game-mode'; Category = 'Sistema'; Default = $true; Risk = 'Baixo'
        Name = 'Modo de Jogo do Windows'
        Description = 'Liga o Game Mode, que dá prioridade de CPU/GPU ao jogo e segura atualizações do Windows durante a partida.'
        Registry = @(
            (RegSet 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1)
            (RegSet 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1)
        )
    }
    @{
        Id = 'hags'; Category = 'Sistema'; Default = $true; Risk = 'Baixo'; Reboot = $true
        Name = 'Agendamento de GPU acelerado por hardware'
        Description = 'Deixa a própria GPU gerenciar sua fila de trabalho (HAGS). Reduz latência em placas NVIDIA GTX 10xx+ / AMD RX 5000+.'
        Registry = @( (RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2) )
    }
    @{
        Id = 'power-throttling'; Category = 'Sistema'; Default = $true; Risk = 'Baixo'; Reboot = $true
        Name = 'Desativar Power Throttling'
        Description = 'Impede o Windows de "economizar" CPU em processos que ele julga estarem em segundo plano (como jogos minimizados ou overlays).'
        Registry = @( (RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1) )
    }
    @{
        Id = 'win32-priority'; Category = 'Sistema'; Default = $true; Risk = 'Baixo'
        Name = 'Prioridade para o programa em primeiro plano'
        Description = 'Ajusta Win32PrioritySeparation (0x26): fatias de CPU curtas e maiores para a janela ativa, melhorando a resposta do jogo.'
        Registry = @( (RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38) )
    }
    @{
        Id = 'background-apps'; Category = 'Sistema'; Default = $true; Risk = 'Baixo'
        Name = 'Bloquear apps em segundo plano'
        Description = 'Impede apps da Microsoft Store de rodarem escondidos consumindo CPU, RAM e rede.'
        Registry = @(
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0)
        )
    }
    @{
        Id = 'startup-delay'; Category = 'Sistema'; Default = $true; Risk = 'Baixo'
        Name = 'Remover atraso de inicialização'
        Description = 'Tira o atraso artificial que o Windows coloca antes de abrir os programas de inicialização.'
        Registry = @( (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0) )
    }
    @{
        Id = 'visual-effects'; Category = 'Sistema'; Default = $false; Risk = 'Baixo'
        Name = 'Efeitos visuais para desempenho'
        Description = 'Desliga transparência e animações do Windows. Ajuda PCs fracos, mas o visual fica mais simples.'
        Registry = @(
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0)
        )
    }

    # ------------------------------------------------------------ Jogos
    @{
        Id = 'game-dvr'; Category = 'Jogos'; Default = $true; Risk = 'Baixo'
        Name = 'Desativar gravação em segundo plano (Game DVR)'
        Description = 'Desliga a captura contínua da Xbox Game Bar, que grava o jogo o tempo todo e rouba FPS.'
        Registry = @(
            (RegSet 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0)
        )
    }
    @{
        Id = 'mmcss-games'; Category = 'Jogos'; Default = $true; Risk = 'Baixo'
        Name = 'Prioridade máxima de jogos no agendador multimídia'
        Description = 'Configura a tarefa "Games" do MMCSS com prioridade alta de GPU e CPU.'
        Registry = @(
            (RegSet "$script:MMCSS\Tasks\Games" 'GPU Priority' 8)
            (RegSet "$script:MMCSS\Tasks\Games" 'Priority' 6)
            (RegSet "$script:MMCSS\Tasks\Games" 'Scheduling Category' 'High' 'String')
            (RegSet "$script:MMCSS\Tasks\Games" 'SFIO Priority' 'High' 'String')
        )
    }
    @{
        Id = 'system-responsiveness'; Category = 'Jogos'; Default = $true; Risk = 'Baixo'
        Name = 'Menos CPU reservada para tarefas de fundo'
        Description = 'Reduz de 20% para 10% a fatia de CPU que o Windows reserva para tarefas de baixa prioridade.'
        Registry = @( (RegSet $script:MMCSS 'SystemResponsiveness' 10) )
    }
    @{
        Id = 'fso-global'; Category = 'Jogos'; Default = $false; Risk = 'Médio'
        Name = 'Desativar otimizações de tela cheia (global)'
        Description = 'Força tela cheia exclusiva em jogos DirectX antigos. Em alguns jogos ajuda, em outros (Windows 11) piora: teste antes.'
        Registry = @(
            (RegSet 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2)
            (RegSet 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2)
            (RegSet 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1)
            (RegSet 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1)
        )
    }

    # ------------------------------------------------------------ Latência / Input
    @{
        Id = 'mouse-accel'; Category = 'Latência e Input'; Default = $true; Risk = 'Baixo'; Reboot = $true
        Name = 'Desativar aceleração do mouse'
        Description = 'Remove o "Aprimorar precisão do ponteiro": a mira passa a responder 1:1 ao movimento. Vale após sair e entrar na conta.'
        Registry = @(
            (RegSet 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String')
            (RegSet 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String')
            (RegSet 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String')
        )
    }
    @{
        Id = 'keyboard-repeat'; Category = 'Latência e Input'; Default = $false; Risk = 'Baixo'; Reboot = $true
        Name = 'Teclado com repetição mais rápida'
        Description = 'Menor atraso e maior velocidade de repetição de teclas.'
        Registry = @(
            (RegSet 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String')
            (RegSet 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String')
        )
    }

    # ------------------------------------------------------------ Rede
    @{
        Id = 'network-throttling'; Category = 'Rede'; Default = $true; Risk = 'Baixo'; Reboot = $true
        Name = 'Desativar limitação de rede multimídia'
        Description = 'Remove o limite de pacotes que o Windows aplica quando há áudio/vídeo tocando (NetworkThrottlingIndex).'
        Registry = @( (RegSet $script:MMCSS 'NetworkThrottlingIndex' -1) )   # -1 = 0xFFFFFFFF
    }
    @{
        Id = 'nagle'; Category = 'Rede'; Default = $true; Risk = 'Baixo'; Reboot = $true
        Name = 'Desativar algoritmo de Nagle'
        Description = 'Envia pacotes TCP na hora em vez de agrupá-los. Reduz ping em jogos que usam TCP (ex.: LoL, MMOs).'
        Apply = {
            param($t)
            $ifaces = @(Get-ActiveTcpInterfaces)
            if (-not $ifaces.Count) { throw 'Nenhuma placa de rede ativa encontrada.' }
            foreach ($i in $ifaces) {
                Set-TrackedRegistry -TweakId $t.Id -Path $i -Name 'TcpAckFrequency' -Value 1
                Set-TrackedRegistry -TweakId $t.Id -Path $i -Name 'TCPNoDelay' -Value 1
            }
        }
        Test = {
            $ifaces = @(Get-ActiveTcpInterfaces)
            if (-not $ifaces.Count) { return $false }
            foreach ($i in $ifaces) {
                $a = Get-RegValue $i 'TcpAckFrequency'; $b = Get-RegValue $i 'TCPNoDelay'
                if (-not $a -or $a.Value -ne 1 -or -not $b -or $b.Value -ne 1) { return $false }
            }
            $true
        }
    }

    # ------------------------------------------------------------ Serviços
    @{
        Id = 'svc-telemetry'; Category = 'Serviços'; Default = $true; Risk = 'Baixo'
        Name = 'Desativar telemetria do Windows'
        Description = 'Para o serviço DiagTrack, que coleta e envia dados de uso em segundo plano.'
        Services = @('DiagTrack')
    }
    @{
        Id = 'svc-sysmain'; Category = 'Serviços'; Default = $false; Risk = 'Médio'
        Name = 'Desativar SysMain (Superfetch)'
        Description = 'Evita uso de disco em segundo plano. Recomendado só para quem tem SSD; em HD pode deixar programas abrindo mais devagar.'
        Services = @('SysMain')
    }
    @{
        Id = 'svc-search'; Category = 'Serviços'; Default = $false; Risk = 'Médio'
        Name = 'Desativar indexação de pesquisa'
        Description = 'Para o Windows Search. Libera disco e CPU, mas a busca do menu Iniciar fica mais lenta.'
        Services = @('WSearch')
    }
    @{
        Id = 'svc-xbox'; Category = 'Serviços'; Default = $false; Risk = 'Médio'
        Name = 'Desativar serviços Xbox'
        Description = 'Para os serviços Xbox Live. NÃO use se joga pelo app Xbox / Game Pass.'
        Services = @('XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc')
    }
)

function Get-Tweak { param([string]$Id) $script:Tweaks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

function Test-TweakApplied {
    param($Tweak)
    try {
        if ($Tweak.Test) { return [bool](& $Tweak.Test) }
        foreach ($r in $Tweak.Registry) {
            $cur = Get-RegValue $r.Path $r.Name
            if (-not $cur -or "$($cur.Value)" -ne "$($r.Value)") { return $false }
        }
        foreach ($s in $Tweak.Services) {
            $cur = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$s" 'Start'
            if ($cur -and $cur.Value -ne 4) { return $false }
        }
        return $true
    } catch { return $false }
}

function Invoke-Tweak {
    param($Tweak)
    Write-Log "Aplicando: $($Tweak.Name)"
    foreach ($r in $Tweak.Registry) {
        Set-TrackedRegistry -TweakId $Tweak.Id -Path $r.Path -Name $r.Name -Value $r.Value -Type $r.Type
    }
    foreach ($s in $Tweak.Services) { Disable-TrackedService $Tweak.Id $s }
    if ($Tweak.Apply) { & $Tweak.Apply $Tweak }
}

function Undo-Tweak {
    param($Tweak)
    Write-Log "Revertendo: $($Tweak.Name)"
    Restore-Backup $Tweak.Id
    if (Test-DryRun) { return }
    foreach ($s in $Tweak.Services) {
        $start = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$s" 'Start'
        if ($start -and $start.Value -le 2) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    }
}

# Reverte tudo que existe no backup (ajustes globais e jogos).
function Undo-All {
    foreach ($id in (Get-BackedUpIds)) {
        $t = Get-Tweak $id
        if ($t) { Undo-Tweak $t } else { Write-Log "Revertendo: $id"; Restore-Backup $id }
    }
}
