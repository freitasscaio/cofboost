# Interface WPF do Overclutch. Os controles com x:Name no XAML ficam em $script:UI.

$script:Pages = @('Home', 'Tweaks', 'Clean', 'Restore', 'Settings')
$script:TweakRows = @{}
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter

function New-Brush { param([string]$Hex) $script:BrushConverter.ConvertFromString($Hex) }
function New-Thickness { param([double]$L, [double]$T, [double]$R, [double]$B) New-Object System.Windows.Thickness($L, $T, $R, $B) }

function Update-UI {
    # Deixa o WPF redesenhar a tela no meio de uma operação longa.
    $script:Window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Set-Status { param([string]$Text) $script:UI.StatusText.Text = $Text; Update-UI }

$script:CoreFile = Join-Path $PSScriptRoot 'Core.ps1'

$script:UpdateFile = Join-Path $PSScriptRoot 'Update.ps1'

# PowerShell em outra thread com o Core e o Update carregados, pronto para rodar $Body
# (texto de script que recebe $Progress).
function New-BackgroundShell {
    param([string]$Body, $Progress)
    $wrapper = {
        param($CoreFile, $UpdateFile, $DataDir, $DryRun, $Body, $Progress)
        . $CoreFile
        # Sem o Update.ps1 (instalação incompleta) só a atualização deixa de funcionar.
        if (Test-Path -LiteralPath $UpdateFile) { . $UpdateFile }
        Initialize-Core -DataDir $DataDir -DryRun:$DryRun
        & ([scriptblock]::Create($Body)) $Progress
    }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($wrapper.ToString()).AddArgument($script:CoreFile).AddArgument($script:UpdateFile).
        AddArgument($script:Core.DataDir).AddArgument([bool]$script:Core.DryRun).AddArgument($Body).AddArgument($Progress)
    $ps
}

# Roda $Body em segundo plano mantendo a janela respondendo. Retorna o último objeto emitido.
function Invoke-InBackground {
    param([string]$Message, [string]$Body)
    $progress = [hashtable]::Synchronized(@{})
    $ps = New-BackgroundShell $Body $progress
    try {
        $handle = $ps.BeginInvoke()
        while (-not $handle.IsCompleted) {
            $text = $Message
            if ($progress.ContainsKey('Files')) { $text += " ($($progress.Files) arquivos)" }
            Set-Status "$text..."
            Start-Sleep -Milliseconds 80
        }
        $result = $ps.EndInvoke($handle)
        if ($ps.Streams.Error.Count) { throw $ps.Streams.Error[0].Exception }
        $result | Select-Object -Last 1
    } finally { $ps.Dispose() }
}

# Como Invoke-InBackground, mas não espera: chama $OnDone ($result, $errorMessage) na
# thread da janela quando terminar. Usado na verificação de atualização ao abrir.
$script:BackgroundJobs = @{}
function Start-InBackground {
    param([string]$Body, [scriptblock]$OnDone)
    $ps = New-BackgroundShell $Body ([hashtable]::Synchronized(@{}))
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:BackgroundJobs[$timer] = @{ Shell = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone }
    $timer.Add_Tick({
        $job = $script:BackgroundJobs[$this]
        if (-not $job.Handle.IsCompleted) { return }
        $this.Stop()
        $script:BackgroundJobs.Remove($this)
        $result = $null; $err = $null
        try {
            $result = $job.Shell.EndInvoke($job.Handle) | Select-Object -Last 1
            if ($job.Shell.Streams.Error.Count) { $err = $job.Shell.Streams.Error[0].Exception.Message }
        } catch { $err = $_.Exception.Message } finally { $job.Shell.Dispose() }
        & $job.OnDone $result $err
    })
    $timer.Start()
}

function Invoke-RestorePointInBackground {
    $ok = Invoke-InBackground 'Criando ponto de restauração (pode levar alguns minutos)' 'param($p) New-RestorePoint'
    if ($ok) { Write-Log 'Ponto de restauração criado.' }
    else { Write-Log 'Não foi possível criar o ponto de restauração (o Windows permite só um a cada 24h).' 'WARN' }
    [bool]$ok
}

function Show-Message {
    param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    [System.Windows.MessageBox]::Show($script:Window, $Text, $script:AppName, $Buttons, $Icon)
}

function Invoke-Busy {
    param([string]$Message, [scriptblock]$Action)
    $script:UI.ContentHost.IsEnabled = $false
    $script:UI.BusyBar.Visibility = 'Visible'
    $script:UI.BusyBar.IsIndeterminate = $true
    Set-Status $Message
    try {
        & $Action
    } catch {
        Write-Log "Erro: $($_.Exception.Message)" 'ERROR'
        Show-Message "Ocorreu um erro:`n$($_.Exception.Message)" 'Error' | Out-Null
    } finally {
        $script:UI.BusyBar.IsIndeterminate = $false
        $script:UI.BusyBar.Visibility = 'Hidden'
        $script:UI.ContentHost.IsEnabled = $true
        Update-State
    }
}

function Show-Page {
    param([string]$Name)
    foreach ($p in $script:Pages) {
        $active = $p -eq $Name
        $script:UI["Page$p"].Visibility = $(if ($active) { 'Visible' } else { 'Collapsed' })
        $btn = $script:UI["Nav$p"]
        $btn.Background = New-Brush $(if ($active) { '#17203A' } else { '#00000000' })
        $btn.Foreground = New-Brush $(if ($active) { '#FFFFFF' } else { '#9AA4BA' })
        $btn.BorderBrush = New-Brush $(if ($active) { '#8B5CF6' } else { '#00000000' })   # indicador lateral
    }
}

function New-Badge {
    $text = New-Object System.Windows.Controls.TextBlock
    $text.FontSize = 11
    $text.FontWeight = [System.Windows.FontWeights]::Bold
    $badge = New-Object System.Windows.Controls.Border
    $badge.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $badge.Padding = New-Thickness 10 4 10 4
    $badge.VerticalAlignment = 'Center'
    $badge.Child = $text
    $badge
}

function Set-Badge {
    param($Badge, [bool]$On, [string]$OnText = 'ATIVO', [string]$OffText = 'INATIVO')
    if ($On) {
        $Badge.Background = New-Brush '#10281F'; $Badge.Child.Foreground = New-Brush '#5BF0B0'; $Badge.Child.Text = $OnText
    } else {
        $Badge.Background = New-Brush '#1A2236'; $Badge.Child.Foreground = New-Brush '#8C97AE'; $Badge.Child.Text = $OffText
    }
}

function New-Card {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = New-Brush '#131A2B'
    $b.BorderBrush = New-Brush '#1F2940'
    $b.BorderThickness = New-Thickness 1 1 1 1
    $b.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $b.Padding = New-Thickness 18 14 18 14
    $b.Margin = New-Thickness 0 0 0 8
    $b
}

function New-Text {
    param([string]$Text, [double]$Size = 13, [string]$Color = '#8A90A2', [switch]$Bold)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = New-Brush $Color
    $t.TextWrapping = 'Wrap'
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $t
}

function New-RowGrid {
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in @('Auto', '*', 'Auto')) {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = $(if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { [System.Windows.GridLength]::Auto })
        $g.ColumnDefinitions.Add($c)
    }
    $g
}

function Build-TweakList {
    $panel = $script:UI.TweakList
    $panel.Children.Clear()
    $script:TweakRows = @{}
    $categories = $script:Tweaks | ForEach-Object { $_.Category } | Select-Object -Unique
    foreach ($cat in $categories) {
        $header = New-Text $cat.ToUpper() 12 '#A78BFA' -Bold
        $header.Margin = New-Thickness 2 14 0 8
        [void]$panel.Children.Add($header)

        foreach ($t in ($script:Tweaks | Where-Object { $_.Category -eq $cat })) {
            $card = New-Card
            $grid = New-RowGrid

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Style = $script:Window.FindResource('SelectBox')
            $cb.IsChecked = [bool]$t.Default
            $cb.VerticalAlignment = 'Center'
            $cb.Margin = New-Thickness 0 0 16 0
            [System.Windows.Controls.Grid]::SetColumn($cb, 0)

            $info = New-Object System.Windows.Controls.StackPanel
            [void]$info.Children.Add((New-Text $t.Name 14 '#FFFFFF' -Bold))
            $tags = @("Risco: $($t.Risk)")
            if ($t.Default) { $tags += 'Recomendado' }
            if ($t.Reboot) { $tags += 'Requer reiniciar' }
            $meta = New-Text ($tags -join '  ·  ') 11 '#A78BFA'
            $meta.Margin = New-Thickness 0 2 0 4
            [void]$info.Children.Add($meta)
            [void]$info.Children.Add((New-Text $t.Description 12))
            [System.Windows.Controls.Grid]::SetColumn($info, 1)

            $badge = New-Badge
            $badge.Margin = New-Thickness 16 0 0 0
            [System.Windows.Controls.Grid]::SetColumn($badge, 2)

            [void]$grid.Children.Add($cb)
            [void]$grid.Children.Add($info)
            [void]$grid.Children.Add($badge)
            $card.Child = $grid

            # Clicar em qualquer lugar do cartão marca/desmarca.
            $card.Cursor = 'Hand'
            $card.Tag = $cb
            $card.Add_MouseLeftButtonUp({ $this.Tag.IsChecked = -not $this.Tag.IsChecked })

            [void]$panel.Children.Add($card)
            $script:TweakRows[$t.Id] = @{ Check = $cb; Badge = $badge }
        }
    }
}

function Update-State {
    $active = 0
    foreach ($t in $script:Tweaks) {
        $on = Test-TweakApplied $t
        if ($on) { $active++ }
        Set-Badge $script:TweakRows[$t.Id].Badge $on
    }
    $total = $script:Tweaks.Count
    $pct = [int][math]::Round(100 * $active / [math]::Max($total, 1))
    $script:UI.ScoreText.Text = "$pct%"
    $script:UI.ScoreDetail.Text = "$active de $total ajustes ativos"
    Set-ScoreArc $pct
    $script:UI.StatusPillText.Text = "$active de $total ajustes ativos"
    $script:UI.StatActive.Text = "$active de $total"

    $undo = @(Get-BackedUpIds).Count
    $script:UI.StatUndo.Text = $(if ($undo) { "$undo item(ns)" } else { 'Nada aplicado' })
    $script:UI.BackupInfo.Text = $(if ($undo) { "O Overclutch guardou os valores originais de $undo item(ns). Desfazer volta todos eles." } else { 'Nenhuma otimização aplicada ainda: não há nada para desfazer.' })
    Set-Status 'Pronto.'
}

# Anel do Painel: arco de 0 a 360° a partir do topo, no sentido horário.
function Set-ScoreArc {
    param([double]$Pct)
    $c = 62; $r = 57
    if ($Pct -le 0) { $script:UI.ScoreArc.Data = $null; return }
    if ($Pct -ge 99.9) { $script:UI.ScoreArc.Data = New-Object System.Windows.Media.EllipseGeometry((New-Object System.Windows.Point($c, $c)), $r, $r); return }
    $a = $Pct / 100 * 2 * [math]::PI
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $x = ($c + $r * [math]::Sin($a)).ToString('0.##', $inv); $y = ($c - $r * [math]::Cos($a)).ToString('0.##', $inv)
    $large = if ($Pct -gt 50) { 1 } else { 0 }
    $script:UI.ScoreArc.Data = [System.Windows.Media.Geometry]::Parse("M $c,$($c - $r) A $r,$r 0 $large 1 $x,$y")
}

function Get-CheckedTweaks {
    $script:Tweaks | Where-Object { $script:TweakRows[$_.Id].Check.IsChecked }
}

# Aplica uma lista de ajustes sem parar no primeiro erro. Retorna se algum pede reinício.
function Invoke-TweakList {
    param($List)
    $list = @($List)
    $reboot = $false
    $i = 0
    foreach ($t in $list) {
        $i++
        Set-Status "Aplicando ($i/$($list.Count)): $($t.Name)"
        try {
            $null = Invoke-Tweak $t
            if ($t.Reboot) { $reboot = $true }
        } catch {
            Write-Log "Falha em '$($t.Name)': $($_.Exception.Message)" 'ERROR'
        }
    }
    $reboot
}

function Register-Handlers {
    foreach ($p in $script:Pages) {
        $script:UI["Nav$p"].Tag = $p
        $script:UI["Nav$p"].Add_Click({ Show-Page $this.Tag })
    }

    $script:UI.BtnBoost.Add_Click({
        $list = @($script:Tweaks | Where-Object { $_.Default })
        $withPoint = [bool](Get-Setting 'RestorePointBeforeBoost')
        $msg = $(if ($withPoint) { 'Vamos criar um ponto de restauração e aplicar' } else { 'Vamos aplicar' }) + " $($list.Count) otimizações recomendadas.`n`nContinuar?"
        if ((Show-Message $msg 'Question' 'YesNo') -ne 'Yes') { return }
        Invoke-Busy 'Otimizando...' {
            if ($withPoint -and -not (Invoke-RestorePointInBackground)) {
                Write-Log 'Seguindo sem ponto de restauração (o backup interno continua valendo).' 'WARN'
            }
            $reboot = Invoke-TweakList $list
            Start-RestorePointList
            $end = 'Otimização concluída!'
            if ($reboot) { $end += "`n`nReinicie o PC para todos os ajustes fazerem efeito." }
            Show-Message $end | Out-Null
        }
    })

    $script:UI.BtnUndoAll.Add_Click({
        if ((Show-Message "Reverter TODAS as otimizações e voltar aos valores originais?" 'Warning' 'YesNo') -ne 'Yes') { return }
        Invoke-Busy 'Revertendo tudo...' {
            Undo-All
            Show-Message "Tudo revertido. Reinicie o PC para concluir." | Out-Null
        }
    })

    $script:UI.BtnApplySelected.Add_Click({
        $list = @(Get-CheckedTweaks)
        if (-not $list.Count) { Show-Message 'Nenhuma otimização marcada.' | Out-Null; return }
        Invoke-Busy 'Aplicando...' {
            $reboot = Invoke-TweakList $list
            if ($reboot) { Show-Message 'Pronto! Alguns ajustes só valem depois de reiniciar o PC.' | Out-Null }
        }
    })

    $script:UI.BtnRevertSelected.Add_Click({
        $list = @(Get-CheckedTweaks)
        if (-not $list.Count) { Show-Message 'Nenhuma otimização marcada.' | Out-Null; return }
        Invoke-Busy 'Revertendo...' {
            foreach ($t in $list) {
                try { Undo-Tweak $t } catch { Write-Log "Falha ao reverter '$($t.Name)': $($_.Exception.Message)" 'ERROR' }
            }
        }
    })

    $script:UI.BtnSelectRecommended.Add_Click({ foreach ($t in $script:Tweaks) { $script:TweakRows[$t.Id].Check.IsChecked = [bool]$t.Default } })
    $script:UI.BtnSelectAll.Add_Click({ foreach ($r in $script:TweakRows.Values) { $r.Check.IsChecked = $true } })
    $script:UI.BtnSelectNone.Add_Click({ foreach ($r in $script:TweakRows.Values) { $r.Check.IsChecked = $false } })

    $script:UI.BtnRestorePoint.Add_Click({
        Invoke-Busy 'Criando ponto de restauração (pode levar alguns minutos)...' {
            if (Invoke-RestorePointInBackground) { Show-Message 'Ponto de restauração criado.' | Out-Null }
            else { Show-Message 'Não foi possível criar o ponto: o Windows permite só um a cada 24 horas, ou a Proteção do Sistema está desligada.' 'Warning' | Out-Null }
            Start-RestorePointList
        }
    })

    $script:UI.BtnOpenRestore.Add_Click({ Start-Process 'rstrui.exe' })
    $script:UI.BtnUndoAllRestore.Add_Click({ $script:UI.BtnUndoAll.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) })
    $script:UI.BtnOpenData.Add_Click({ Start-Process 'explorer.exe' $script:Core.DataDir })
    $script:UI.BtnOpenLog.Add_Click({
        if (Test-Path -LiteralPath $script:Core.LogFile) { Start-Process 'notepad.exe' $script:Core.LogFile }
        else { Show-Message 'O registro ainda está vazio.' | Out-Null }
    })

    # Limpeza: um botão por item e o "Limpar tudo".
    foreach ($pair in @(@('BtnCleanTemp', 'temp'), @('BtnCleanThumbs', 'thumbs'), @('BtnCleanUpdate', 'update'), @('BtnCleanBin', 'bin'))) {
        $script:UI[$pair[0]].Tag = $pair[1]
        $script:UI[$pair[0]].Add_Click({ $id = $this.Tag; Invoke-Busy 'Limpando...' { Show-CleanupResult @(Invoke-Cleanup $id) } })
    }
    $script:UI.BtnFlushDns.Add_Click({ Invoke-Busy 'Limpando DNS...' { Clear-Dns; Show-Message 'Cache DNS limpo.' | Out-Null } })
    $script:UI.BtnCleanAll.Add_Click({
        if ((Show-Message "Limpar temporários, miniaturas, cache do Windows Update, Lixeira e DNS?" 'Question' 'YesNo') -ne 'Yes') { return }
        Invoke-Busy 'Limpando tudo...' {
            $results = @(foreach ($id in $script:CleanupTargets.Keys) { Invoke-Cleanup $id })
            Clear-Dns
            Show-CleanupResult $results -WithDns
        }
    })

    # Configurações
    $script:UI.ToggleCheckUpdates.IsChecked = [bool](Get-Setting 'CheckUpdates')
    $script:UI.ToggleRestoreBefore.IsChecked = [bool](Get-Setting 'RestorePointBeforeBoost')
    $script:UI.ToggleCheckUpdates.Add_Click({ Set-Setting 'CheckUpdates' ([bool]$this.IsChecked) })
    $script:UI.ToggleRestoreBefore.Add_Click({ Set-Setting 'RestorePointBeforeBoost' ([bool]$this.IsChecked) })

    # Redes sociais e GitHub (link vazio em $script:Links esconde o ícone).
    foreach ($name in $script:Links.Keys) {
        foreach ($btn in @($script:UI["Link$name"], $script:UI["About$name"]) | Where-Object { $_ }) {
            $btn.Tag = $script:Links[$name]
            $btn.Visibility = $(if ($script:Links[$name]) { 'Visible' } else { 'Collapsed' })
            $btn.Add_Click({ if ($this.Tag -match '^https://') { Start-Process $this.Tag } })
        }
    }

    $script:UI.BtnUpdateNow.Add_Click({ Invoke-UpdateNow })
    $script:UI.BtnUpdateLater.Add_Click({ $script:UI.UpdateBanner.Visibility = 'Collapsed' })
    $script:UI.BtnCheckUpdate.Add_Click({
        Invoke-Busy 'Verificando atualizações...' {
            $rel = Invoke-InBackground 'Verificando atualizações' 'param($p) Get-LatestRelease'
            if (Test-NewerVersion $rel.Version $script:AppVersion) {
                Show-UpdateBanner $rel
                $answer = Show-Message "A versão $($rel.Version) está disponível (você tem a $($script:AppVersion)).`n`nAtualizar agora?" 'Question' 'YesNo'
                if ($answer -eq 'Yes') { $script:UpdateAfterBusy = $true }
            } else {
                $script:UI.UpdateInfo.Text = "Você está na versão mais recente ($($script:AppVersion))."
                Show-Message "Você já está na versão mais recente ($($script:AppVersion))." | Out-Null
            }
        }
        if ($script:UpdateAfterBusy) { $script:UpdateAfterBusy = $false; Invoke-UpdateNow }
    })
}

# ---------------------------------------------------------------- limpeza

# Itens da aba Limpeza. Body roda em segundo plano e devolve Files/Bytes/Skipped.
$script:CleanupTargets = [ordered]@{
    temp   = @{ Name = 'Arquivos temporários';      Body = 'param($p) Clear-TempFiles -Progress $p' }
    thumbs = @{ Name = 'Cache de miniaturas';       Body = 'param($p) Clear-ThumbnailCache' }
    update = @{ Name = 'Cache do Windows Update';   Body = 'param($p) Clear-WindowsUpdateCache' }
    bin    = @{ Name = 'Lixeira';                    Body = 'param($p) Clear-RecycleBinSafe' }
}

function Invoke-Cleanup {
    param([string]$Id)
    $target = $script:CleanupTargets[$Id]
    $r = Invoke-InBackground "Limpando: $($target.Name)" $target.Body
    [pscustomobject]@{ Name = $target.Name; Files = [int]$r.Files; Bytes = [long]$r.Bytes; Skipped = [int]$r.Skipped }
}

function Show-CleanupResult {
    param($Results, [switch]$WithDns)
    $lines = foreach ($r in @($Results)) {
        $detail = if ($r.Files) { "$(Format-Size $r.Bytes) ($($r.Files) itens)" } else { 'já estava limpo' }
        if ($r.Skipped) { $detail += ", $($r.Skipped) em uso mantidos" }
        "$($r.Name): $detail"
    }
    if ($WithDns) { $lines = @($lines) + 'Cache DNS: limpo' }
    $total = (@($Results) | Measure-Object Bytes -Sum).Sum
    $head = if (Test-DryRun) { "Modo simulação: $(Format-Size $total) seriam liberados. Nada foi apagado." } else { "$(Format-Size $total) liberados." }
    Write-Log "Limpeza: $head $($lines -join '; ')"
    Show-Message ($head + "`n`n" + ($lines -join "`n")) | Out-Null
}

# ---------------------------------------------------------------- restauração

# Lista os pontos de restauração do Windows na aba Restauração e o último no Painel.
function Start-RestorePointList {
    Start-InBackground 'param($p) ,@(Get-RestorePoints)' {
        param($points, $err)
        $points = @($points | ForEach-Object { $_ } | Where-Object { $_ })
        $list = $script:UI.RestoreList
        $list.Children.Clear()
        if (-not $points.Count) {
            [void]$list.Children.Add((New-Text 'Nenhum ponto de restauração encontrado. Crie um antes de mudanças grandes.' 13))
            $script:UI.StatRestore.Text = 'Nenhum'
            return
        }
        foreach ($pt in $points | Select-Object -First 8) {
            $row = New-Object System.Windows.Controls.Grid
            $row.Height = 44
            $name = New-Text $pt.Description 13.5 '#FFFFFF'
            $name.VerticalAlignment = 'Center'; $name.TextTrimming = 'CharacterEllipsis'; $name.TextWrapping = 'NoWrap'
            $name.Margin = New-Thickness 0 0 160 0
            $date = New-Text ($pt.Date.ToString('dd/MM/yyyy HH:mm')) 13 '#8C97AE'
            $date.HorizontalAlignment = 'Right'; $date.VerticalAlignment = 'Center'
            [void]$row.Children.Add($name); [void]$row.Children.Add($date)
            [void]$list.Children.Add($row)
            $line = New-Object System.Windows.Controls.Border
            $line.Height = 1; $line.Background = New-Brush '#1F2940'
            [void]$list.Children.Add($line)
        }
        $script:UI.StatRestore.Text = $points[0].Date.ToString('dd/MM/yyyy HH:mm')
    }
}
# ---------------------------------------------------------------- atualização

function Show-UpdateBanner {
    param($Release)
    $script:PendingUpdate = $Release
    $script:UI.UpdateTitle.Text = "Nova versão $($Release.Version) disponível"
    $script:UI.UpdateDetail.Text = "Você está na $($script:AppVersion). A atualização baixa o instalador oficial do GitHub e mantém suas otimizações."
    $script:UI.UpdateInfo.Text = "Versão $($Release.Version) disponível (você tem a $($script:AppVersion))."
    $script:UI.UpdateBanner.Visibility = 'Visible'
    $script:UI.StatUpdate.Text = "Versão $($Release.Version) disponível"
    $script:UI.StatUpdate.Foreground = New-Brush '#C4B5FD'
    Write-Log "Atualização disponível: $($Release.Version)."
}

# Ao abrir: consulta o GitHub sem travar a janela. Sem internet, não mostra nada.
function Start-UpdateCheck {
    Start-InBackground 'param($p) Get-LatestRelease' {
        param($rel, $err)
        if ($err) { $script:UI.StatUpdate.Text = 'Sem conexão'; Write-Log "Verificação de atualização falhou: $err" 'WARN'; return }
        if ($rel -and (Test-NewerVersion $rel.Version $script:AppVersion)) { Show-UpdateBanner $rel }
        else { $script:UI.StatUpdate.Text = "Em dia (v$($script:AppVersion))" }
    }
}

function Invoke-UpdateNow {
    $rel = $script:PendingUpdate
    if (-not $rel -or -not (Test-ReleaseInfo $rel)) { return }
    $script:UpdateStarted = $false
    Invoke-Busy "Baixando a versão $($rel.Version)..." {
        # Os valores já passaram por Test-ReleaseInfo (só dígitos, URL do repositório e hex).
        $body = "param(`$p) Save-UpdateInstaller ([pscustomobject]@{ Version = '$($rel.Version)'; Url = '$($rel.Url)'; Size = $([long]$rel.Size); Sha256 = '$($rel.Sha256)' })"
        $path = Invoke-InBackground "Baixando a versão $($rel.Version)" $body
        Start-UpdateInstaller $path
        $script:UpdateStarted = $true
    }
    # O instalador substitui os arquivos e reabre o app; esta janela fecha para não atrapalhar.
    if ($script:UpdateStarted) { $script:Window.Close() }
}

# Sem isso a barra de tarefas agrupa a janela com o PowerShell e mostra o ícone dele.
# O mesmo id está nos atalhos criados pelo instalador.
$script:AppUserModelId = 'Overclutch.App'

$script:TaskbarCode = @'
using System;
using System.Runtime.InteropServices;
namespace Overclutch {
    public static class Taskbar {
        [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public uint pid; }
        // PROPVARIANT tem 24 bytes no x64; só usamos vt e o ponteiro da string.
        [StructLayout(LayoutKind.Explicit, Size = 24)] struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IPropertyStore {
            int GetCount(out uint c); int GetAt(uint i, out PROPERTYKEY k);
            int GetValue(ref PROPERTYKEY k, out PROPVARIANT v); int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v); int Commit();
        }
        [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, out IPropertyStore s);
        [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
        // Windows 11: cantos arredondados (DWMWA_WINDOW_CORNER_PREFERENCE = 33, ROUND = 2).
        public static void RoundCorners(IntPtr hwnd) { int v = 2; DwmSetWindowAttribute(hwnd, 33, ref v, 4); }

        static readonly Guid AppModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        static void Set(IPropertyStore s, uint pid, string value) {
            var k = new PROPERTYKEY { fmtid = AppModel, pid = pid };
            var v = new PROPVARIANT { vt = 31 /* VT_LPWSTR */, p = Marshal.StringToCoTaskMemUni(value) };
            try { s.SetValue(ref k, ref v); } finally { Marshal.FreeCoTaskMem(v.p); }
        }

        // Grava na janela o id do app e, se houver o Overclutch.exe, o que o Windows
        // deve abrir e qual ícone usar quando a janela é fixada na barra de tarefas.
        public static void Apply(IntPtr hwnd, string appId, string exe, string name) {
            Guid iid = typeof(IPropertyStore).GUID; IPropertyStore s;
            if (SHGetPropertyStoreForWindow(hwnd, ref iid, out s) != 0) return;
            try {
                if (exe != null) {
                    Set(s, 2, "\"" + exe + "\"");   // RelaunchCommand
                    Set(s, 3, exe + ",0");          // RelaunchIconResource
                    Set(s, 4, name);                // RelaunchDisplayNameResource
                }
                Set(s, 5, appId);                   // ID
                s.Commit();
            } finally { Marshal.ReleaseComObject(s); }
        }
    }
}
'@

function Set-TaskbarIdentity {
    try {
        Add-Type -TypeDefinition $script:TaskbarCode -ErrorAction Stop
        [void][Overclutch.Taskbar]::SetCurrentProcessExplicitAppUserModelID($script:AppUserModelId)
        $exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'Overclutch.exe'
        $script:LauncherExe = if (Test-Path -LiteralPath $exe) { $exe } else { $null }
        $script:Window.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
            try { [Overclutch.Taskbar]::Apply($hwnd, $script:AppUserModelId, $script:LauncherExe, $script:AppName) } catch { }
            try { [Overclutch.Taskbar]::RoundCorners($hwnd) } catch { }
        })
    } catch { }
}

# Poppins vem em assets\fonts (licença OFL). Sem os arquivos, fica a fonte do Windows.
function Set-AppFont {
    $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\fonts'
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'Poppins-Regular.ttf'))) { return }
    try {
        $family = New-Object System.Windows.Media.FontFamily(([Uri]('file:///' + ($dir -replace '\\', '/') + '/')), './#Poppins')
        $script:Window.FontFamily = $family
        $script:Window.Resources['Display'] = $family
    } catch { }
}

# Barra de título própria: minimizar, maximizar e fechar. Maximizada, a janela sem
# moldura passa um pouco da tela; a margem compensa.
function Register-WindowChrome {
    $script:UI.BtnMin.Add_Click({ $script:Window.WindowState = 'Minimized' })
    $script:UI.BtnMax.Add_Click({
        $script:Window.WindowState = $(if ($script:Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' })
    })
    $script:UI.BtnClose.Add_Click({ $script:Window.Close() })
    $script:Window.Add_StateChanged({
        $max = $script:Window.WindowState -eq 'Maximized'
        $script:UI.RootBorder.Margin = New-Thickness $(if ($max) { 7 } else { 0 }) $(if ($max) { 7 } else { 0 }) $(if ($max) { 7 } else { 0 }) $(if ($max) { 7 } else { 0 })
        $script:UI.BtnMax.ToolTip = $(if ($max) { 'Restaurar' } else { 'Maximizar' })
    })
}

# Cartões de hardware do Painel: coleta em segundo plano (WMI demora um pouco).
function Start-SystemInfo {
    Start-InBackground 'param($p) Get-SystemInfo' {
        param($info, $err)
        if (-not $info) { return }
        $map = @{ CpuText = 'Cpu'; GpuText = 'Gpu'; RamText = 'Ram'; DiskText = 'Disk'; OsText = 'Os'; OsVersionText = 'OsVersion'; OsBuildText = 'OsBuild'; DiskModelText = 'DiskModel' }
        foreach ($k in $map.Keys) { $v = "$($info.($map[$k]))"; $script:UI[$k].Text = $(if ($v) { $v } else { '—' }) }
        foreach ($chip in 'CpuChip', 'GpuChip', 'RamChip', 'DiskChip') {
            $v = "$($info.$chip)"
            $script:UI[$chip].Text = $v
            $script:UI[$chip].Parent.Visibility = $(if ($v) { 'Visible' } else { 'Collapsed' })
        }
        foreach ($k in 'CpuText', 'GpuText', 'RamText', 'DiskText') { $script:UI[$k].ToolTip = $script:UI[$k].Text }
        if ($info.CpuThreads) { $script:UI.CpuText.ToolTip = "$($info.Cpu): $($info.CpuThreads)" }
    }
}

function Start-App {
    [xml]$xml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml') -Raw -Encoding UTF8
    $script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    Set-TaskbarIdentity
    $script:UI = @{}
    foreach ($node in $xml.SelectNodes("//*[@*[local-name()='Name']]")) {
        $name = ($node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1).Value
        $ctrl = $script:Window.FindName($name)
        if ($ctrl) { $script:UI[$name] = $ctrl }
    }

    $script:UI.VersionText.Text = "v$($script:AppVersion)"
    Set-AppFont
    $iconFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\overclutch.png'
    if (Test-Path -LiteralPath $iconFile) {
        # CacheOption OnLoad lê o arquivo inteiro e solta na hora; sem isso o PNG fica
        # travado enquanto o app roda e o instalador não consegue atualizar.
        try {
            $img = New-Object System.Windows.Media.Imaging.BitmapImage
            $img.BeginInit()
            $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $img.UriSource = [Uri]$iconFile
            $img.EndInit()
            $img.Freeze()
            $script:Window.Icon = $img
            $script:UI.TitleLogo.Source = $img
            $script:UI.AboutLogo.Source = $img
        } catch { }
    }
    if (Test-DryRun) {
        $script:UI.ModeText.Text = 'Modo simulação: nada é alterado de verdade.'
        $script:UI.ModeText.Foreground = New-Brush '#FBBF24'
        $script:UI.ModeBadge.Visibility = 'Visible'
        $script:Window.Title = "$($script:AppName) (simulação)"
    } else {
        $script:UI.ModeText.Text = 'Modo administrador'
    }
    $first = ("$env:USERNAME" -split '[\s._-]')[0]
    $script:UI.GreetingText.Text = $(if ($first) { "Olá, " + $first.Substring(0, 1).ToUpper() + $first.Substring(1) } else { 'Olá' })
    Register-WindowChrome

    Start-SystemInfo
    Start-RestorePointList

    Build-TweakList
    Register-Handlers
    Show-Page 'Home'
    Update-State
    Write-Log "$($script:AppName) $($script:AppVersion) iniciado$(if (Test-DryRun) { ' em modo simulação' })."
    $script:UI.UpdateInfo.Text = "Versão instalada: $($script:AppVersion). Confere no GitHub se há uma mais nova."
    $script:UI.AboutVersion.Text = "Overclutch $($script:AppVersion)"
    if (Get-Setting 'CheckUpdates') { Start-UpdateCheck } else { $script:UI.StatUpdate.Text = 'Verificação desligada' }

    [void]$script:Window.ShowDialog()
}
