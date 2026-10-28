# CofBoost

Otimizador de Windows para jogos: mais FPS e menos input lag em 1 clique, com **todas as alterações reversíveis**. Grátis e open source ([MIT](LICENSE)).

Não precisa instalar nada além do que já vem no Windows 10/11 (PowerShell 5.1 + WPF).

## Recursos

- **Otimizar agora (1 clique):** cria um ponto de restauração e aplica as otimizações recomendadas.
- **25 otimizações** em 6 categorias (Sistema, Jogos, Latência e Input, Rede, Recursos do Windows, Serviços), cada uma com descrição, nível de risco e um indicador ATIVO/INATIVO.
- **Limpeza:** arquivos temporários, cache de miniaturas, cache do Windows Update, Lixeira e cache DNS, um por um ou tudo de uma vez.
- **Restauração:** cria e lista pontos de restauração do Windows e desfaz as otimizações do CofBoost.
- **Configurações:** verificar atualizações ao abrir, criar ponto de restauração antes de otimizar, dados e registro.
- **Desfazer tudo:** antes de mudar qualquer coisa, o valor original é salvo em `C:\ProgramData\CofBoost\backup.json`, e cada ajuste volta exatamente ao que era.
- **Modo simulação** (`Simular.bat`): mostra no Registro tudo o que seria alterado, sem mudar nada.
- **Atualização pelo app:** ao abrir, o app consulta o GitHub Releases. Se houver uma versão nova, aparece uma faixa com **Atualizar agora**: o app baixa o instalador oficial, confere o SHA-256 publicado pelo GitHub, instala e reabre. Também dá para verificar em **Ferramentas > Verificar atualizações**.

## Instalação

Baixe o **CofBoost-Setup.exe** na página de [Releases](https://github.com/freitasscaio/overclutch/releases/latest) e siga o assistente.

- Não pede senha de administrador para instalar. O app pede permissão (UAC) só quando vai otimizar.
- Cria atalhos no Menu Iniciar (normal e modo simulação) e, se você quiser, na Área de Trabalho.
- Aparece em **Configurações > Aplicativos instalados**. Ao desinstalar, ele pergunta se você quer reverter as otimizações antes.
- Se o Windows mostrar "O Windows protegeu o computador", clique em **Mais informações > Executar assim mesmo**. Isso acontece porque o instalador ainda não tem assinatura digital.

### Para desenvolvedores

```powershell
git clone https://github.com/freitasscaio/overclutch.git
cd cofboost
.\Iniciar.bat                                              # roda direto da pasta
powershell -ExecutionPolicy Bypass -File install.ps1       # instalação rápida, sem assistente
```

## Gerar o instalador

Precisa do [Inno Setup 6](https://jrsoftware.org/isinfo.php) (`winget install --id JRSoftware.InnoSetup -e`).

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

O build roda os testes, compila o `CofBoost.exe` (com o `csc.exe` do .NET Framework, que já vem no Windows) e gera `dist\CofBoost-Setup.exe`. A versão vem de `$script:AppVersion` em `src/Core.ps1`.

### Publicar uma versão

O workflow `.github/workflows/release.yml` roda os testes em todo push. Ao criar uma tag, ele gera o instalador e publica no GitHub Releases:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

O site baixa sempre de `releases/latest/download/CofBoost-Setup.exe`, então não precisa mudar o link a cada versão.
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
| Recursos do Windows | Desativar Copilot | ✔ |
| Recursos do Windows | Desativar Widgets | ✔ |
| Recursos do Windows | Desativar Recall | ✔ |
| Recursos do Windows | Desativar sobreposição da Xbox Game Bar | |
| Recursos do Windows | Desativar isolamento de núcleo (risco alto) | |
| Serviços | Desativar telemetria (DiagTrack) | ✔ |
| Serviços | Desativar SysMain | |
| Serviços | Desativar o Windows Search | |
| Serviços | Desativar os serviços Xbox | |

Para adicionar uma otimização nova, inclua um item em `src/Tweaks.ps1`. A aplicação, a verificação e a reversão funcionam sozinhas para valores de registro (`Registry`) e serviços (`Services`).

## Estrutura

```
CofBoost.ps1      ponto de entrada (pede administrador)
launcher/           CofBoost.exe: abre o app sem console e com o ícone na barra de tarefas
Iniciar.bat         atalho para abrir
Simular.bat         abre em modo simulação
install.ps1         instalação rápida para desenvolvimento
build.ps1           testes + instalador (dist\CofBoost-Setup.exe)
installer/          script do Inno Setup
assets/             ícone do app e fonte Poppins (licença OFL, assets/fonts/OFL.txt)
tools/make-icon.ps1 gera o ícone
site/               site do projeto
src/Core.ps1        backup, registro, log, ponto de restauração, limpeza
src/Tweaks.ps1      catálogo de otimizações
src/Update.ps1      verificação e instalação de atualizações (GitHub Releases)
src/UI.ps1          lógica da interface
src/MainWindow.xaml layout da interface (WPF)
tests/Run-Tests.ps1 testes (não alteram o sistema)
```

## Site

A página fica em `site/index.html`: um arquivo só, sem build, com as imagens em `site/assets/`.
No bloco `CONFIG`, no fim do arquivo, troque `freitasscaio` pelo seu usuário do GitHub nos links do repositório e do download.

Para ver no seu PC:

```powershell
python -m http.server 8765 --directory site
```

Para publicar de graça, arraste a pasta `site` no **Netlify Drop** (app.netlify.com/drop) ou importe o repositório na **Vercel** com `site` como diretório raiz.
### Privacidade e documentos legais

O site não usa cookies, rastreamento nem formulários, e não carrega nada de terceiros sozinho (a fonte Poppins é servida pelo próprio site). Os documentos ficam em `site/privacidade.html`, `site/termos.html` e `site/licencas.html`.

Antes de publicar o site, rode o verificador. Ele acusa campos pendentes nos documentos (nome do responsável e e-mail) e qualquer script, fonte ou imagem de terceiros:

```powershell
powershell -ExecutionPolicy Bypass -File tools\check-site.ps1
```

Se um dia o site passar a usar Google Analytics ou outra ferramenta de medição, a Política de Privacidade precisa ser atualizada e o script só pode carregar depois do consentimento do visitante.
## Testes

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\Run-Tests.ps1
```

Teste da interface (abre o app em modo simulação e clica em todos os botões; precisa de uma sessão com tela):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\Run-UiTests.ps1
```

## Avisos

- Os ganhos de FPS variam muito de PC para PC. Os maiores ganhos costumam aparecer em PCs com o Windows "de fábrica".
- Os scripts `.ps1` precisam ficar salvos em **UTF-8 com BOM**, senão os acentos quebram no PowerShell 5.1 (os testes verificam isso).
- Se você abrir o app com uma conta de administrador diferente da sua, os ajustes de usuário (HKCU) vão para essa outra conta.
- Projeto independente, sem relação com nenhum outro otimizador comercial.
