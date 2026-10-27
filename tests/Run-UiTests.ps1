<#
.SYNOPSIS
    Teste de ponta a ponta da interface: abre o app em MODO SIMULAÇÃO e clica em cada
    botão, como um usuário faria, registrando mensagens e erros. Nada é alterado no PC.
    Ficam de fora só os botões que abrem outros programas (Restauração do Sistema,
    Explorer, Bloco de Notas, links) e o "Atualizar agora" (instalaria de verdade).
    Uso: powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\Run-UiTests.ps1
#>
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $root 'src\Core.ps1'); . (Join-Path $root 'src\Tweaks.ps1')
. (Join-Path $root 'src\Update.ps1'); . (Join-Path $root 'src\UI.ps1')

$data = Join-Path ([IO.Path]::GetTempPath()) ("overclutch-ui-" + [guid]::NewGuid())
Initialize-Core -DataDir $data -DryRun

# Caixas de mensagem respondem "Sim" sozinhas e ficam anotadas.
$script:Messages = New-Object System.Collections.ArrayList
function Show-Message { param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    [void]$script:Messages.Add("[$Icon] $($Text -replace "`r?`n", ' ')"); if ($Buttons -eq 'YesNo') { 'Yes' } else { 'OK' } }

$script:Results = New-Object System.Collections.ArrayList
$script:Failures = 0
function Check { param([bool]$Ok, [string]$What)
    [void]$script:Results.Add($(if ($Ok) { "  OK    $What" } else { $script:Failures++; "  FALHA $What" })) }
function Click { param([string]$Name)
    $btn = $script:UI[$Name]
    if (-not $btn) { Check $false "botão $Name existe"; return }
    $btn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}
function Errors-Since { param([int]$From)
    @(Get-Content -LiteralPath $script:Core.LogFile -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Skip $From | Where-Object { $_ -match '\[ERROR\]' }) }
function Log-Count { @(Get-Content -LiteralPath $script:Core.LogFile -Encoding UTF8 -ErrorAction SilentlyContinue).Count }

# Cada passo: nome + ação. Depois de cada um, confere se não apareceu ERROR no log.
$script:Steps = [System.Collections.Queue]::new()
function Step { param([string]$Name, [scriptblock]$Do) $script:Steps.Enqueue(@{ Name = $Name; Do = $Do }) }

Step 'Abrir e verificar atualização' {
    Check ($script:Tweaks.Count -eq $script:TweakRows.Count) "lista mostra os $($script:Tweaks.Count) ajustes"
    Check ($script:UI.ScoreText.Text -match '^\d+%$') "porcentagem na tela inicial ($($script:UI.ScoreText.Text))"
    Check ($script:UI.CpuText.Text -ne '...') "informações do PC carregadas ($($script:UI.CpuText.Text))"
    Check ($null -ne $script:Window.Icon) 'ícone da janela carregado'
}
Step 'Navegar por todas as páginas' {
    foreach ($p in $script:Pages) { Click "Nav$p"; Check ($script:UI["Page$p"].Visibility -eq 'Visible') "página $p abre" }
}
Step 'Marcar todas / desmarcar / recomendadas' {
    Click 'BtnSelectAll';  Check (@($script:TweakRows.Values | Where-Object { $_.Check.IsChecked }).Count -eq $script:Tweaks.Count) 'Marcar todas'
    Click 'BtnSelectNone'; Check (@($script:TweakRows.Values | Where-Object { $_.Check.IsChecked }).Count -eq 0) 'Desmarcar'
    Click 'BtnSelectRecommended'; Check (@($script:TweakRows.Values | Where-Object { $_.Check.IsChecked }).Count -eq @($script:Tweaks | Where-Object Default).Count) 'Marcar recomendadas'
}
Step 'Aplicar selecionadas (simulação)' { Click 'BtnSelectAll'; Click 'BtnApplySelected' }
Step 'Reverter selecionadas (simulação)' { Click 'BtnRevertSelected'; Click 'BtnSelectRecommended' }
Step 'Otimizar agora (simulação)' { Click 'BtnBoost'; Check ([bool]($script:Messages -match 'Otimização concluída')) 'mensagem de conclusão' }
Step 'Desfazer tudo (simulação)' { Click 'BtnUndoAll'; Check ([bool]($script:Messages -match 'Tudo revertido')) 'mensagem de reversão' }
Step 'Limpeza: cada item (simulação)' {
    foreach ($b in 'BtnCleanTemp', 'BtnCleanThumbs', 'BtnCleanUpdate', 'BtnCleanBin') {
        $before = $script:Messages.Count; Click $b
        Check ($script:Messages.Count -gt $before -and $script:Messages[-1] -match 'Nada foi apagado') "$b mostra o resultado da simulação"
    }
    Click 'BtnFlushDns'; Check ([bool]($script:Messages -match 'DNS limpo')) 'Limpar DNS'
}
Step 'Limpeza: limpar tudo (simulação)' {
    Click 'BtnCleanAll'
    $last = $script:Messages[-1]
    Check ($last -match 'Arquivos temporários' -and $last -match 'Lixeira' -and $last -match 'Cache DNS') "resumo com todos os itens"
}
Step 'Restauração' {
    Click 'BtnRestorePoint'; Check ([bool]($script:Messages -match 'Ponto de restauração criado')) 'criar ponto de restauração'
    Check ($script:UI.RestoreList.Children.Count -ge 1) 'lista de pontos de restauração preenchida'
    Check ($script:UI.BackupInfo.Text -ne '...') "situação do backup ($($script:UI.BackupInfo.Text))"
    $before = $script:Messages.Count; Click 'BtnUndoAllRestore'
    Check ($script:Messages.Count -gt $before) 'Desfazer na aba Restauração funciona'
}
Step 'Configurações' {
    $orig = [bool](Get-Setting 'CheckUpdates')
    $script:UI.ToggleCheckUpdates.IsChecked = -not $orig
    $script:UI.ToggleCheckUpdates.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Check ([bool](Get-Setting 'CheckUpdates') -eq (-not $orig)) 'chave "verificar atualizações" salva a escolha'
    Check ($script:UI.AboutVersion.Text -match [regex]::Escape($script:AppVersion)) "Sobre mostra a versão ($($script:UI.AboutVersion.Text))"
    Check ($script:UI.LinkGitHub.Visibility -eq 'Visible') 'ícone do GitHub no menu'
    Check (($script:Links.Keys | Where-Object { -not $script:Links[$_] } | ForEach-Object { $script:UI["Link$_"].Visibility }) -notcontains 'Visible') 'redes sem link ficam escondidas'
}
Step 'Fonte e Painel' {
    Check ($script:Window.FontFamily.Source -match 'Poppins') "fonte da janela: $($script:Window.FontFamily.Source)"
    Check ($script:UI.CpuText.Text -notin '...', '') "hardware carregado ($($script:UI.CpuText.Text), $($script:UI.GpuText.Text))"
    Check ($script:UI.StatRestore.Text -ne '...') "último ponto de restauração: $($script:UI.StatRestore.Text)"
    Check ($null -ne $script:UI.ScoreArc.Data -or $script:UI.ScoreText.Text -eq '0%') 'anel de progresso desenhado'
}
Step 'Verificar atualizações' { Click 'BtnCheckUpdate'; Check ([bool]($script:Messages -match 'versão')) 'resposta da verificação' }
Step 'Faixa de atualização: Depois' {
    Show-UpdateBanner ([pscustomobject]@{ Version = '9.9.9'; Url = "https://github.com/$($script:UpdateRepo)/releases/download/v9.9.9/Overclutch-Setup.exe"; Size = 1; Sha256 = $null })
    Check ($script:UI.UpdateBanner.Visibility -eq 'Visible') 'faixa aparece'
    Click 'BtnUpdateLater'; Check ($script:UI.UpdateBanner.Visibility -eq 'Collapsed') 'Depois esconde a faixa'
}

$script:Busy = $false
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:StartedAt = Get-Date
$timer.Add_Tick({
    if ($script:Busy -or -not $script:UI.ContentHost.IsEnabled) { return }
    if (((Get-Date) - $script:StartedAt).TotalSeconds -lt 4) { return }   # deixa a verificação de atualização terminar
    if ($script:Steps.Count -eq 0) { $this.Stop(); $script:Window.Close(); return }
    $script:Busy = $true
    $s = $script:Steps.Dequeue()
    [void]$script:Results.Add($s.Name)
    $from = Log-Count
    try { & $s.Do } catch { Check $false "sem exceção: $($_.Exception.Message)" }
    $errs = Errors-Since $from
    Check ($errs.Count -eq 0) $(if ($errs.Count) { "sem erros no log: $($errs -join ' | ')" } else { 'sem erros no log' })
    $script:Busy = $false
})
$timer.Start()
Start-App

$script:Results | ForEach-Object { if ($_ -match 'FALHA') { Write-Host $_ -ForegroundColor Red } elseif ($_ -match '^  OK') { Write-Host $_ -ForegroundColor Green } else { Write-Host $_ } }
Write-Host ''
Write-Host 'Mensagens mostradas ao usuário:'; $script:Messages | ForEach-Object { Write-Host "  $_" }
Write-Host ''
if ($script:Steps.Count) { Write-Host "Passos que não rodaram: $($script:Steps.Count)" -ForegroundColor Red; $script:Failures++ }
Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failures) { Write-Host "$($script:Failures) verificação(ões) falharam." -ForegroundColor Red; exit 1 }
Write-Host 'Todas as funcionalidades responderam sem erro.' -ForegroundColor Green
