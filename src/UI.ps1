# Interface WPF do Overclutch. Os controles com x:Name no XAML ficam em $script:UI.

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

$script:UpdateFile = Join-Path $PSScriptRoot 'Update.ps1'
$script:GamesFile  = Join-Path $PSScriptRoot 'Games.ps1'

# PowerShell em outra thread com o Core, Games e Update carregados, pronto para rodar
# $Body (texto de script que recebe $Progress).
function New-BackgroundShell {
    param([string]$Body, $Progress)
    $wrapper = {
        param($CoreFile, $UpdateFile, $DataDir, $DryRun, $Body, $Progress, $GamesFile)
        . $CoreFile
        . $GamesFile
        # Sem o Update.ps1 (instalação incompleta) só a atualização deixa de funcionar.
        if (Test-Path -LiteralPath $UpdateFile) { . $UpdateFile }
        Initialize-Core -DataDir $DataDir -DryRun:$DryRun
        & ([scriptblock]::Create($Body)) $Progress
    }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($wrapper.ToString()).AddArgument($script:CoreFile).AddArgument($script:UpdateFile).
        AddArgument($script:Core.DataDir).AddArgument([bool]$script:Core.DryRun).AddArgument($Body).AddArgument($Progress).AddArgument($script:GamesFile)
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

function New-ImageFromFile {
    param([string]$Path)
    # OnLoad lê o arquivo e solta na hora (não trava a capa nem o ícone).
    $img = New-Object System.Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $img.DecodePixelWidth = 496
    $img.UriSource = [Uri]$Path
    $img.EndInit()
    $img.Freeze()
    $img
}

function Get-ExeIconSource {
    param([string]$Exe)
    try {
        Add-Type -AssemblyName System.Drawing
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Exe)
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze(); $ico.Dispose()
        $src
    } catch { $null }
}

# Área da capa: a imagem do jogo ou, sem capa, o ícone do .exe sobre um fundo escuro.
function New-GameCover {
    param($Game, [bool]$Exists)
    $cover = New-Object System.Windows.Controls.Border
    $cover.Height = 116
    $cover.CornerRadius = New-Object System.Windows.CornerRadius(11, 11, 0, 0)
    $file = Get-CoverFile $Game.Path
    $image = $null
    if (Test-Path -LiteralPath $file) { try { $image = New-ImageFromFile $file } catch { } }
    if ($image) {
        $brush = New-Object System.Windows.Media.ImageBrush($image)
        $brush.Stretch = 'UniformToFill'
        $cover.Background = $brush
        return $cover
    }
    $cover.Background = New-Brush '#1D1838'
    $icon = if ($Exists) { Get-ExeIconSource $Game.Path } else { $null }
    if ($icon) {
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $icon; $img.Width = 48; $img.Height = 48
        $cover.Child = $img
    } else {
        $initials = -join (($Game.Name -split '\s+' | Where-Object { $_ } | Select-Object -First 2) | ForEach-Object { $_.Substring(0, 1).ToUpper() })
        $text = New-Text $initials 30 '#A78BFA' -Bold
        $text.HorizontalAlignment = 'Center'; $text.VerticalAlignment = 'Center'
        $cover.Child = $text
    }
    $cover
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
        $exists = Test-Path -LiteralPath $g.Path
        $tile = New-Object System.Windows.Controls.Border
        $tile.Width = 248
        $tile.Margin = New-Thickness 0 0 14 14
        $tile.CornerRadius = New-Object System.Windows.CornerRadius(12)
        $tile.Background = New-Brush '#141821'
        $tile.BorderBrush = New-Brush '#232838'
        $tile.BorderThickness = New-Thickness 1 1 1 1
        $tile.ToolTip = "$($g.Name)`n$($g.Path)"

        $stack = New-Object System.Windows.Controls.StackPanel
        [void]$stack.Children.Add((New-GameCover $g $exists))

        $body = New-Object System.Windows.Controls.StackPanel
        $body.Margin = New-Thickness 14 12 14 14
        $name = New-Text $g.Name 14 '#FFFFFF' -Bold
        $name.TextWrapping = 'NoWrap'
        $name.TextTrimming = 'CharacterEllipsis'
        [void]$body.Children.Add($name)
        if (-not $exists) {
            $missing = New-Text 'Arquivo do jogo não encontrado' 11 '#FBBF24'
            $missing.Margin = New-Thickness 0 2 0 0
            [void]$body.Children.Add($missing)
        }

        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = New-Thickness 0 12 0 0
        $remove = New-Object System.Windows.Controls.Button
        $remove.Style = $script:Window.FindResource('SecondaryButton')
        $remove.Padding = New-Thickness 12 5 12 5
        $remove.FontSize = 12
        $remove.Content = 'Remover'
        $remove.Tag = $g.Path
        $remove.Add_Click({
            $path = $this.Tag
            Invoke-Busy 'Removendo jogo...' { Remove-Game $path }
        })
        [System.Windows.Controls.DockPanel]::SetDock($remove, 'Right')
        [void]$row.Children.Add($remove)
        $badge = New-Badge
        $badge.HorizontalAlignment = 'Left'
        Set-Badge $badge (Test-GameBoosted $g) 'OTIMIZADO' 'NORMAL'
        [void]$row.Children.Add($badge)
        [void]$body.Children.Add($row)

        [void]$stack.Children.Add($body)
        $tile.Child = $stack
        [void]$panel.Children.Add($tile)
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
            $found = @(Invoke-InBackground 'Procurando jogos na Steam, Epic, Riot, EA, Ubisoft, GOG, Battle.net e Xbox' 'param($p) ,@(Find-InstalledGames)' | ForEach-Object { $_ })
            $added = @(Add-DetectedGames $found)
            $msg = if ($added.Count) { "$($added.Count) jogo(s) adicionado(s):`n" + ($added -join "`n") }
                   elseif ($found.Count) { "Todos os $($found.Count) jogos encontrados já estão na lista." }
                   else { 'Nenhum jogo encontrado nas lojas. Use "Adicionar .exe manualmente".' }
            Show-Message $msg | Out-Null
            Start-CoverFetch
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
            Start-CoverFetch
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
            $size = Format-Size $r.Bytes
            $kept = if ($r.Skipped) { "`n$($r.Skipped) arquivo(s) em uso por outros programas foram mantidos." } else { '' }
            if (Test-DryRun) {
                Write-Log "[SIMULAÇÃO] Temporários: $($r.Files) arquivos ($size) seriam apagados."
                Show-Message "Modo simulação: $size seriam liberados ($($r.Files) arquivos). Nada foi apagado." | Out-Null
            } elseif ($r.Files -eq 0) {
                Write-Log "Temporários: nada para apagar.$($kept -replace "`n", ' ')"
                Show-Message "As pastas temporárias já estão limpas.$kept" | Out-Null
            } else {
                Write-Log "Temporários: $($r.Files) arquivos apagados ($size).$($kept -replace "`n", ' ')"
                Show-Message "$size liberados ($($r.Files) arquivos).$kept" | Out-Null
            }
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

# ---------------------------------------------------------------- jogos

# Ao abrir: procura jogos novos em segundo plano e já coloca na lista (menos os que o
# usuário removeu de propósito).
function Start-GameScan {
    Start-InBackground 'param($p) ,@(Find-InstalledGames)' {
        param($found, $err)
        if ($err) { Write-Log "Busca de jogos falhou: $err" 'WARN'; return }
        $added = @(Add-DetectedGames $found -Automatic)
        if ($added.Count) {
            Write-Log "$($added.Count) jogo(s) novo(s) encontrado(s): $($added -join ', ')."
            Build-GameList
        }
        Start-CoverFetch
    }
}

# Busca as capas que faltam (cache da Steam ou loja da Steam) e redesenha os cartões.
function Start-CoverFetch {
    Start-InBackground 'param($p) Update-GameCovers' {
        param($saved, $err)
        if ($err) { Write-Log "Busca de capas falhou: $err" 'WARN'; return }
        if ($saved) { Build-GameList }
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
    Write-Log "Atualização disponível: $($Release.Version)."
}

# Ao abrir: consulta o GitHub sem travar a janela. Sem internet, não mostra nada.
function Start-UpdateCheck {
    Start-InBackground 'param($p) Get-LatestRelease' {
        param($rel, $err)
        if ($err) { Write-Log "Verificação de atualização falhou: $err" 'WARN'; return }
        if ($rel -and (Test-NewerVersion $rel.Version $script:AppVersion)) { Show-UpdateBanner $rel }
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
        })
    } catch { }
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
        } catch { }
    }
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
    $script:UI.UpdateInfo.Text = "Versão instalada: $($script:AppVersion). Confere no GitHub se há uma mais nova."
    Start-UpdateCheck
    Start-GameScan

    [void]$script:Window.ShowDialog()
}
