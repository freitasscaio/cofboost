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

# ---------------------------------------------------------------- opções do plano de energia
# Valores de um item do plano ativo (ex.: suspensão seletiva de USB). O powercfg mostra
# o índice atual na tomada (AC) e na bateria (DC) como os dois últimos números 0x... da saída.
$script:PowerSettings = @{
    UsbSuspend = @{ Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' }
    PcieAspm   = @{ Sub = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5' }
}

function Get-PowerSettingValue {
    param([string]$Scheme, [string]$Sub, [string]$Setting)
    $out = powercfg /query $Scheme $Sub $Setting 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $hex = @([regex]::Matches(($out -join "`n"), '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt32($_.Groups[1].Value, 16) })
    if ($hex.Count -lt 2) { return $null }
    [pscustomobject]@{ AC = $hex[-2]; DC = $hex[-1] }
}

function Set-PowerSettingValue {
    param([string]$Scheme, [string]$Sub, [string]$Setting, [int]$AC, [int]$DC)
    powercfg /setacvalueindex $Scheme $Sub $Setting $AC | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg não aceitou o valor $AC para $Setting" }
    powercfg /setdcvalueindex $Scheme $Sub $Setting $DC | Out-Null
    # Reativar o plano faz o Windows ler os valores novos na hora.
    if ((Get-ActiveSchemeGuid) -eq $Scheme) { powercfg /setactive $Scheme | Out-Null }
}

# Grava o valor original (do plano ativo) no backup antes de mudar, como o Set-TrackedRegistry.
function Set-TrackedPowerSetting {
    param([string]$TweakId, [string]$Key, [int]$Value)
    $ps = $script:PowerSettings[$Key]
    $scheme = Get-ActiveSchemeGuid
    if (-not $scheme) { throw 'Não foi possível ler o plano de energia atual.' }
    $cur = Get-PowerSettingValue $scheme $ps.Sub $ps.Setting
    if (-not $cur) { throw 'Esta opção de energia não existe neste PC.' }
    if (Test-DryRun) { Write-Log "[SIMULAÇÃO] Plano $scheme : $Key = $Value (atual: $($cur.AC))"; return }
    $already = Get-BackupEntries $TweakId | Where-Object { $_.Kind -eq 'PowerSetting' -and $_.Scheme -eq $scheme -and $_.Setting -eq $ps.Setting }
    if (-not $already) {
        Add-BackupEntry $TweakId ([pscustomobject]@{ Kind = 'PowerSetting'; Scheme = $scheme; Sub = $ps.Sub; Setting = $ps.Setting; AC = $cur.AC; DC = $cur.DC })
    }
    Set-PowerSettingValue $scheme $ps.Sub $ps.Setting $Value $Value
    Write-Log "Plano $scheme : $Key = $Value"
}

function Test-PowerSetting {
    param([string]$Key, [int]$Value)
    $ps = $script:PowerSettings[$Key]
    $scheme = Get-ActiveSchemeGuid
    if (-not $scheme) { return $false }
    $cur = Get-PowerSettingValue $scheme $ps.Sub $ps.Setting
    [bool]($cur -and $cur.AC -eq $Value)
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
        Id = 'fast-startup'; Category = 'Sistema'; Default = $false; Risk = 'Baixo'; Reboot = $true
        Name = 'Desativar Inicialização Rápida'
        Description = 'Faz o "Desligar" zerar o Windows de verdade, recarregando drivers limpos a cada boot. Resolve travadinhas que só somem reiniciando. O PC liga alguns segundos mais devagar.'
        Registry = @( (RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0) )
    }
    @{
        Id = 'visual-effects'; Category = 'Sistema'; Default = $false; Risk = 'Baixo'
        Name = 'Efeitos visuais para desempenho'
        Description = 'Desliga transparência e animações do Windows. Ajuda PCs fracos, mas o visual fica mais simples. As letras continuam suaves (ClearType).'
        Registry = @(
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0)
            # O modo "melhor desempenho" do Windows também desliga a suavização de fontes,
            # o que deixa o texto serrilhado em todo o sistema. Mantém ligada (ClearType).
            (RegSet 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String')
            (RegSet 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2)
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
    @{
        Id = 'usb-suspend'; Category = 'Latência e Input'; Default = $true; Risk = 'Baixo'
        Name = 'Desativar suspensão seletiva de USB'
        Description = 'O Windows para de "adormecer" as portas USB para economizar energia. Mouse, teclado e headset ficam sempre acordados, sem engasgos ao voltar do repouso.'
        Apply = { param($t) Set-TrackedPowerSetting $t.Id 'UsbSuspend' 0 }
        Test  = { Test-PowerSetting 'UsbSuspend' 0 }
    }
    @{
        Id = 'pcie-aspm'; Category = 'Latência e Input'; Default = $true; Risk = 'Baixo'
        Name = 'Desativar economia de energia do PCI Express'
        Description = 'Desliga o "Gerenciamento de Energia do Estado de Link": a placa de vídeo e o SSD NVMe não entram em modo econômico entre um frame e outro. Em notebook, gasta um pouco mais de bateria.'
        Apply = { param($t) Set-TrackedPowerSetting $t.Id 'PcieAspm' 0 }
        Test  = { Test-PowerSetting 'PcieAspm' 0 }
    }
    @{
        Id = 'accessibility-hotkeys'; Category = 'Latência e Input'; Default = $true; Risk = 'Baixo'
        Name = 'Desativar atalhos de Teclas de Aderência e Filtro'
        Description = 'Apertar Shift 5 vezes ou segurar o Shift não abre mais a janela de acessibilidade por cima do jogo. Os recursos continuam disponíveis em Configurações.'
        Registry = @(
            (RegSet 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String')
            (RegSet 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String')
            (RegSet 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String')
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

    # ------------------------------------------------------------ Recursos do Windows
    @{
        Id = 'copilot'; Category = 'Recursos do Windows'; Default = $true; Risk = 'Baixo'; Reboot = $true
        Name = 'Desativar Copilot'
        Description = 'Desliga o Copilot do Windows e tira o botão dele da barra de tarefas.'
        Registry = @(
            (RegSet 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1)
            (RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0)
        )
    }
    @{
        Id = 'widgets'; Category = 'Recursos do Windows'; Default = $true; Risk = 'Baixo'; Reboot = $true
        Name = 'Desativar Widgets'
        Description = 'Desliga o painel de Widgets (notícias e clima), que fica carregando conteúdo em segundo plano.'
        Registry = @( (RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0) )
    }
    @{
        Id = 'recall'; Category = 'Recursos do Windows'; Default = $true; Risk = 'Baixo'; Reboot = $true
        Name = 'Desativar Recall (IA do Windows)'
        Description = 'Impede o Windows de tirar capturas da tela para a linha do tempo do Recall. Libera disco e CPU.'
        Registry = @(
            (RegSet 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1)
            (RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1)
        )
    }
    @{
        Id = 'gamebar-overlay'; Category = 'Recursos do Windows'; Default = $false; Risk = 'Baixo'
        Name = 'Desativar sobreposição da Xbox Game Bar'
        Description = 'Win+G deixa de abrir a Game Bar por cima do jogo. Não use se grava clipes ou usa o chat de voz dela.'
        Registry = @(
            (RegSet 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0)
            (RegSet 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0)
        )
    }
    @{
        Id = 'windows-tips'; Category = 'Recursos do Windows'; Default = $true; Risk = 'Baixo'
        Name = 'Desativar dicas e sugestões do Windows'
        Description = 'Tira as dicas, "sugestões" de apps e telas de boas-vindas que o Windows mostra sozinho, inclusive notificações no meio do jogo.'
        Registry = @(
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 0)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0)
            (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0)
        )
    }
    @{
        Id = 'advertising-id'; Category = 'Recursos do Windows'; Default = $true; Risk = 'Baixo'
        Name = 'Desativar ID de publicidade'
        Description = 'Impede que apps usem um identificador seu para mostrar anúncios personalizados.'
        Registry = @( (RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0) )
    }
    @{
        Id = 'delivery-optimization'; Category = 'Recursos do Windows'; Default = $true; Risk = 'Baixo'
        Name = 'Não enviar atualizações para outros PCs'
        Description = 'Desliga a Otimização de Entrega em modo P2P: o Windows para de usar sua internet para mandar atualizações a outros computadores. As suas atualizações continuam chegando normalmente.'
        Registry = @( (RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0) )
    }
    @{
        Id = 'edge-background'; Category = 'Recursos do Windows'; Default = $false; Risk = 'Baixo'
        Name = 'Impedir o Edge de rodar em segundo plano'
        Description = 'Desliga o "Aumento de inicialização" e a execução em segundo plano do Microsoft Edge depois de fechado. O Edge pode mostrar "gerenciado pela sua organização" por usar uma política.'
        Registry = @(
            (RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0)
            (RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0)
        )
    }
    @{
        Id = 'core-isolation'; Category = 'Recursos do Windows'; Default = $false; Risk = 'Alto'; Reboot = $true
        Name = 'Desativar isolamento de núcleo (Integridade de Memória)'
        Description = 'Pode dar alguns FPS a mais, mas desliga uma proteção do Windows contra drivers maliciosos. Só ative se souber o que está fazendo.'
        Registry = @( (RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0) )
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
