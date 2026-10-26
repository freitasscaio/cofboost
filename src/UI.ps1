# Interface WPF do NitroFPS. Os controles com x:Name no XAML ficam em $script:UI.

$script:Pages = @('Home', 'Tweaks', 'Games', 'Tools', 'Log')
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

# Roda $Body (texto de script que recebe $Progress) em outra thread com o Core carregado,
# mantendo a janela respondendo. Retorna o último objeto que o script emitir.
function Invoke-InBackground {
    param([string]$Message, [string]$Body)
    $progress = [hashtable]::Synchronized(@{})
    $wrapper = {
        param($CoreFile, $DataDir, $DryRun, $Body, $Progress)
        . $CoreFile
        Initialize-Core -DataDir $DataDir -DryRun:$DryRun
        & ([scriptblock]::Create($Body)) $Progress
    }
    $ps = [PowerShell]::Create()
    try {
        [void]$ps.AddScript($wrapper.ToString()).AddArgument($script:CoreFile).AddArgument($script:Core.DataDir).
            AddArgument([bool]$script:Core.DryRun).AddArgument($Body).AddArgument($progress)
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
        $btn.Background = New-Brush $(if ($active) { '#221B3A' } else { '#00000000' })
        $btn.Foreground = New-Brush $(if ($active) { '#FFFFFF' } else { '#B8BDCC' })
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
        $Badge.Background = New-Brush '#12301F'; $Badge.Child.Foreground = New-Brush '#4ADE80'; $Badge.Child.Text = $OnText
    } else {
        $Badge.Background = New-Brush '#1E2230'; $Badge.Child.Foreground = New-Brush '#8A90A2'; $Badge.Child.Text = $OffText
    }
}

function New-Card {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = New-Brush '#141821'
    $b.BorderBrush = New-Brush '#232838'
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

function Build-GameList {
    $panel = $script:UI.GameList
    $panel.Children.Clear()
    if ($script:Games.Count -eq 0) {
        $empty = New-Text 'Nenhum jogo na lista. Clique em "Detectar jogos instalados" ou adicione um .exe manualmente.' 13
        $empty.Margin = New-Thickness 2 10 0 0
        [void]$panel.Children.Add($empty)
        return
    }
    foreach ($g in $script:Games) {
        $card = New-Card
        $grid = New-RowGrid

        $badge = New-Badge
        $badge.Margin = New-Thickness 0 0 16 0
        $exists = Test-Path -LiteralPath $g.Path
        Set-Badge $badge (Test-GameBoosted $g) 'OTIMIZADO' 'NORMAL'
        [System.Windows.Controls.Grid]::SetColumn($badge, 0)

        $info = New-Object System.Windows.Controls.StackPanel
        [void]$info.Children.Add((New-Text $g.Name 14 '#FFFFFF' -Bold))
        $pathText = if ($exists) { $g.Path } else { "$($g.Path)  (arquivo não encontrado)" }
        [void]$info.Children.Add((New-Text $pathText 11))
        [System.Windows.Controls.Grid]::SetColumn($info, 1)

        $remove = New-Object System.Windows.Controls.Button
        $remove.Style = $script:Window.FindResource('SecondaryButton')
        $remove.Content = 'Remover'
        $remove.Tag = $g.Path
        $remove.Margin = New-Thickness 16 0 0 0
        $remove.VerticalAlignment = 'Center'
        $remove.Add_Click({
            $path = $this.Tag
            Invoke-Busy 'Removendo jogo...' { Remove-Game $path }
        })
        [System.Windows.Controls.Grid]::SetColumn($remove, 2)

        [void]$grid.Children.Add($badge)
        [void]$grid.Children.Add($info)
        [void]$grid.Children.Add($remove)
        $card.Child = $grid
        [void]$panel.Children.Add($card)
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
    $script:UI.ScoreBar.Value = $pct
    Build-GameList
    Set-Status 'Pronto.'
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

function Invoke-GameBoostAll {
    foreach ($g in $script:Games) {
        if (-not (Test-Path -LiteralPath $g.Path)) { continue }
        Set-Status "Otimizando jogo: $($g.Name)"
        try { Invoke-GameBoost $g } catch { Write-Log "Falha no jogo '$($g.Name)': $($_.Exception.Message)" 'ERROR' }
    }
}

function Register-Handlers {
    foreach ($p in $script:Pages) {
        $script:UI["Nav$p"].Tag = $p
        $script:UI["Nav$p"].Add_Click({ Show-Page $this.Tag })
    }

    $script:UI.BtnBoost.Add_Click({
        $list = @($script:Tweaks | Where-Object { $_.Default })
        $msg = "Vamos criar um ponto de restauração e aplicar $($list.Count) otimizações recomendadas" +
               $(if ($script:Games.Count) { " + boost em $($script:Games.Count) jogo(s)" } else { '' }) + ".`n`nContinuar?"
        if ((Show-Message $msg 'Question' 'YesNo') -ne 'Yes') { return }
        Invoke-Busy 'Criando ponto de restauração...' {
            if (-not (Invoke-RestorePointInBackground)) {
                Write-Log 'Seguindo sem ponto de restauração (o backup interno continua valendo).' 'WARN'
            }
            $reboot = Invoke-TweakList $list
            Invoke-GameBoostAll
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

    $script:UI.BtnDetectGames.Add_Click({
        Invoke-Busy 'Procurando jogos instalados...' {
            $added = 0
            foreach ($g in @(Find-InstalledGames)) { if (Add-Game $g.Name $g.Path) { $added++ } }
            Show-Message $(if ($added) { "$added jogo(s) encontrado(s) e adicionado(s)." } else { 'Nenhum jogo novo encontrado. Use "Adicionar .exe manualmente".' }) | Out-Null
        }
    })

    $script:UI.BtnAddGame.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Escolha o executável do jogo'
        $dlg.Filter = 'Executáveis (*.exe)|*.exe'
        if ($dlg.ShowDialog($script:Window)) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
            Add-Game $name $dlg.FileName | Out-Null
            Update-State
        }
    })

    $script:UI.BtnBoostGames.Add_Click({
        if (-not $script:Games.Count) { Show-Message 'Adicione ou detecte jogos primeiro.' | Out-Null; return }
        Invoke-Busy 'Otimizando jogos...' { Invoke-GameBoostAll }
    })

    $script:UI.BtnUnboostGames.Add_Click({
        Invoke-Busy 'Removendo boost dos jogos...' {
            foreach ($g in $script:Games) { Undo-GameBoost $g }
        }
    })

    $script:UI.BtnCleanTemp.Add_Click({
        Invoke-Busy 'Limpando arquivos temporários...' {
            $r = Invoke-InBackground 'Limpando arquivos temporários' 'param($p) Clear-TempFiles -Progress $p'
            $prefix = if (Test-DryRun) { '[SIMULAÇÃO] ' } else { '' }
            Write-Log "${prefix}Temporários: $($r.Files) arquivos apagados ($($r.MB) MB), $($r.Skipped) em uso foram mantidos."
            Show-Message "$($r.MB) MB liberados ($($r.Files) arquivos).`n$($r.Skipped) arquivo(s) em uso por outros programas foram mantidos." | Out-Null
        }
    })

    $script:UI.BtnFlushDns.Add_Click({ Invoke-Busy 'Limpando DNS...' { Clear-Dns; Show-Message 'Cache DNS limpo.' | Out-Null } })

    $script:UI.BtnRestorePoint.Add_Click({
        Invoke-Busy 'Criando ponto de restauração (pode levar alguns minutos)...' {
            if (Invoke-RestorePointInBackground) { Show-Message 'Ponto de restauração criado.' | Out-Null }
            else { Show-Message 'Não foi possível criar o ponto (o Windows permite só um a cada 24h). Veja o Registro.' 'Warning' | Out-Null }
        }
    })

    $script:UI.BtnOpenRestore.Add_Click({ Start-Process 'rstrui.exe' })
    $script:UI.BtnOpenData.Add_Click({ Start-Process 'explorer.exe' $script:Core.DataDir })
}

function Start-App {
    [xml]$xml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml') -Raw -Encoding UTF8
    $script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    $script:UI = @{}
    foreach ($node in $xml.SelectNodes("//*[@*[local-name()='Name']]")) {
        $name = ($node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1).Value
        $ctrl = $script:Window.FindName($name)
        if ($ctrl) { $script:UI[$name] = $ctrl }
    }

    $script:UI.VersionText.Text = "v$($script:AppVersion)"
    if (Test-DryRun) {
        $script:UI.ModeText.Text = 'MODO SIMULAÇÃO: nada é alterado de verdade.'
        $script:UI.ModeText.Foreground = New-Brush '#FBBF24'
        $script:Window.Title = "$($script:AppName) (simulação)"
    } else {
        $script:UI.ModeText.Text = 'Executando como administrador'
    }

    $script:Core.OnLog = {
        param($line)
        $script:UI.LogBox.AppendText("$line`r`n")
        $script:UI.LogBox.ScrollToEnd()
    }

    $info = Get-SystemInfo
    $script:UI.CpuText.Text = $info.Cpu
    $script:UI.GpuText.Text = $info.Gpu
    $script:UI.RamText.Text = $info.Ram
    $script:UI.OsText.Text  = $info.Os

    Import-Games
    Build-TweakList
    Register-Handlers
    Show-Page 'Home'
    Update-State
    Write-Log "$($script:AppName) $($script:AppVersion) iniciado$(if (Test-DryRun) { ' em modo simulação' })."

    [void]$script:Window.ShowDialog()
}
