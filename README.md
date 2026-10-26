# NitroFPS

Otimizador de Windows para jogos: mais FPS e menos input lag em 1 clique, com **todas as alterações reversíveis**.

Não precisa instalar nada além do que já vem no Windows 10/11 (PowerShell 5.1 + WPF).

## Recursos

- **Otimizar agora (1 clique):** cria um ponto de restauração e aplica as otimizações recomendadas.
- **20 otimizações** em 5 categorias (Sistema, Jogos, Latência e Input, Rede, Serviços), cada uma com descrição, nível de risco e um indicador ATIVO/INATIVO.
- **Boost por jogo:** detecta CS2, Valorant, LoL, Fortnite, Dota 2, Rocket League, Apex, PUBG, R6, GTA V e Roblox (ou qualquer `.exe` que você adicionar) e força a GPU dedicada + prioridade alta de CPU.
- **Ferramentas:** limpar arquivos temporários, limpar o cache DNS, criar um ponto de restauração.
- **Desfazer tudo:** antes de mudar qualquer coisa, o valor original é salvo em `C:\ProgramData\NitroFPS\backup.json`, e cada ajuste volta exatamente ao que era.
- **Modo simulação** (`Simular.bat`): mostra no Registro tudo o que seria alterado, sem mudar nada.

## Instalação

```powershell
git clone https://github.com/SEU-USUARIO/nitrofps.git
cd nitrofps
powershell -ExecutionPolicy Bypass -File install.ps1
```

Isso copia o app para `%LOCALAPPDATA%\Programs\NitroFPS` e cria atalhos na Área de Trabalho e no Menu Iniciar.
Também dá para abrir sem instalar, com um duplo clique em `Iniciar.bat`.

Para desinstalar (use **Desfazer todas as otimizações** no app antes):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

## Otimizações

| Categoria | Ajuste | Recomendado |
|---|---|---|
| Sistema | Plano de energia Desempenho Máximo | ✔ |
| Sistema | Modo de Jogo do Windows | ✔ |
| Sistema | Agendamento de GPU acelerado por hardware (HAGS) | ✔ |
| Sistema | Desativar Power Throttling | ✔ |
| Sistema | Win32PrioritySeparation (prioridade para a janela ativa) | ✔ |
| Sistema | Bloquear apps em segundo plano | ✔ |
| Sistema | Remover atraso de inicialização | ✔ |
| Sistema | Efeitos visuais para desempenho | |
| Jogos | Desativar Game DVR | ✔ |
| Jogos | Prioridade de jogos no MMCSS | ✔ |
| Jogos | SystemResponsiveness = 10 | ✔ |
| Jogos | Desativar otimizações de tela cheia (global) | |
| Latência e Input | Desativar aceleração do mouse | ✔ |
| Latência e Input | Repetição de teclado mais rápida | |
| Rede | NetworkThrottlingIndex desativado | ✔ |
| Rede | Desativar o algoritmo de Nagle | ✔ |
| Serviços | Desativar telemetria (DiagTrack) | ✔ |
| Serviços | Desativar SysMain | |
| Serviços | Desativar o Windows Search | |
| Serviços | Desativar os serviços Xbox | |

Para adicionar uma otimização nova, inclua um item em `src/Tweaks.ps1`. A aplicação, a verificação e a reversão funcionam sozinhas para valores de registro (`Registry`) e serviços (`Services`).

## Estrutura

```
NitroFPS.ps1        ponto de entrada (pede administrador)
Iniciar.bat         atalho para abrir
Simular.bat         abre em modo simulação
install.ps1         instala/desinstala
src/Core.ps1        backup, registro, log, ponto de restauração, limpeza
src/Tweaks.ps1      catálogo de otimizações
src/Games.ps1       detecção de jogos e boost por executável
src/UI.ps1          lógica da interface
src/MainWindow.xaml layout da interface (WPF)
tests/Run-Tests.ps1 testes (não alteram o sistema)
```

## Testes

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\Run-Tests.ps1
```

## Avisos

- Os ganhos de FPS variam muito de PC para PC. Os maiores ganhos costumam aparecer em PCs com o Windows "de fábrica".
- Os scripts `.ps1` precisam ficar salvos em **UTF-8 com BOM**, senão os acentos quebram no PowerShell 5.1 (os testes verificam isso).
- Se você abrir o app com uma conta de administrador diferente da sua, os ajustes de usuário (HKCU) vão para essa outra conta.
- Projeto independente, sem relação com nenhum outro otimizador comercial.
