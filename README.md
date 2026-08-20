# voz-ao-claude

**Clarisse** dá voz ao [Claude Code](https://claude.com/claude-code) no Windows. Quando o Claude termina uma resposta, ela dá um bipe curto — e fala em voz alta o que foi feito, os números que apareceram e o que ficou pendente **quando você apertar `Ctrl+Alt+L`**.

O Claude Code já **ouve** você (voice mode). Este projeto fecha o outro lado: ele passa a **responder falando**.

## Por que isso existe

Nasceu de um problema concreto de acessibilidade: dificuldade de concentração para ler respostas longas na tela, levando a erros por não ler tudo — um valor conferido errado, um aviso ignorado, uma pendência que passou batido.

A solução não é ler a resposta inteira em voz alta. Isso é pior: TTS fala ~150 palavras/min e ninguém aguenta ouvir caminho de arquivo e bloco de código. A Clarisse fala **só o que não pode passar**:

- o resultado do que acabou de rodar;
- o achado ou a conclusão — dito por inteiro, não anunciado;
- o que ainda falta ou precisa da sua decisão;
- valores, prazos e datas, ditos devagar;
- avisos antes de qualquer ação irreversível;
- quando o Claude para esperando sua permissão.

O detalhe e o código continuam na tela. O áudio é o resultado.

**Resumo não é aviso.** A instrução no `CLAUDE.md` proíbe explicitamente frases ocas: nada de "encontrei um problema" sem dizer qual, ou "preciso da sua decisão" sem dizer qual. Se o resumo menciona algo que exige ação, o conteúdo vem na mesma frase.

**Você decide a hora de ouvir.** Voz que dispara sozinha atropela quem está no meio de outra coisa — e se você a corta, perde o que ela ia dizer. Por isso o fim de uma resposta só emite um bipe; a fala sai no seu comando, e você pode pausá-la e retomá-la do mesmo ponto.

## Como funciona

Uma skill não produz som — skill é só texto de instrução. Quem produz som são **hooks**, que o Claude Code executa sozinho em pontos do ciclo de vida.

```
você fala  ──►  Claude Code (voice mode)  ──►  Claude trabalha
                                                     │
                                    escreve o resumo em fala.txt
                                                     │
                                          hook Stop dispara
                                                     │
                              resumo entra na fila  ──►  🔔 bipe curto
                                                     │
                                          você aperta Ctrl+Alt+L
                                                     │
                       edge-tts gera o 1º pedaço ──► 🔊 Clarisse fala
                                                     │
                              o resto é gerado enquanto ela fala
```

| Peça | Papel |
|---|---|
| `clarisse/nucleo.ps1` | Núcleo compartilhado: config, saneamento do texto, segmentação, caixa de entrada, fila, controle do áudio |
| `clarisse/clarisse.ps1` | Motor: gera o áudio e reproduz |
| `clarisse/falar.py` | Sintetiza a fala em pedaços, em fluxo, para a voz começar quase na hora |
| `clarisse/atalhos.ps1` | Escutador residente dos atalhos globais |
| Hook `Stop` | Enfileira o resumo e bipa quando o Claude termina |
| Hook `Notification` | **Fala** qual projeto parou pedindo permissão — ali o Claude está travado esperando você |
| Hook `SessionStart` | Religa a voz e sobe o escutador a cada sessão nova |
| `comandos/clarisse.md` | Slash command `/clarisse` |
| `docs/INSTRUCOES-CLAUDE.md` | Bloco anexado ao seu `CLAUDE.md` que instrui o Claude a escrever o resumo |

### Atalhos

| Tecla | O que faz |
|---|---|
| `Ctrl+Alt+L` | Lê o resumo que está na fila |
| `Ctrl+Alt+P` | Pausa a fala; aperte de novo e ela **retoma do mesmo ponto** |
| `Ctrl+Alt+X` | Cancela a fala na hora |

As três combinações são configuráveis. Elas funcionam com qualquer janela em foco — inclusive fora do terminal.

Isso exige um processo residente: um `powershell.exe` oculto registra as teclas via `RegisterHotKey` do Win32 e dorme em `GetMessage`, sem consumir CPU. Ele **continua rodando depois que você fecha o Claude Code** — é o que faz o atalho responder a qualquer momento. `/clarisse status` mostra se ele está de pé e `/clarisse atalhos off` o encerra.

A pausa é pausa de verdade, não um "matar e recomeçar": o reprodutor lê um arquivo de controle a cada 120 ms e usa `Pause()`/`Play()` do `MediaPlayer`.

### A fala começa antes do áudio estar pronto

Gerar o áudio inteiro antes de tocar a primeira nota custava **33 segundos de silêncio** num resumo de 1.500 caracteres — e o tempo cresce junto com o texto, então ampliar o limite da fala piorou isso sem ninguém perceber.

O texto é cortado em pedaços e sintetizado **em fluxo**: a fala começa no primeiro pedaço enquanto o resto ainda está sendo gerado. Medido na mesma máquina, com o mesmo resumo: **33 s → 3 s**. Sintetizar é cerca de 3× mais rápido que falar, então depois do primeiro pedaço a geração corre na frente da voz e não engasga.

O primeiro pedaço é deliberadamente curto, porque é ele que define a espera. Cortar demais também custa: cada pedaço é uma ida ao servidor de voz.

O sinal de "pode tocar" é um arquivo-sentinela escrito **depois** de o mp3 ser fechado — a existência do mp3 não serve, porque um arquivo ainda em gravação abre no player com duração errada e corta a fala no meio. De brinde, `Ctrl+Alt+X` responde em 0,4 s, e um pedaço corrompido custa uma frase em vez do resumo inteiro.

### Várias sessões abertas ao mesmo tempo

Todas as sessões do Claude Code compartilham a mesma pasta `~/.claude/clarisse`, e o atalho é global no nível do sistema operacional — ele não tem como saber qual terminal você está olhando.

Por isso cada sessão escreve o resumo na **sua própria caixa** — `entrada/<projeto>.txt` — em vez de num arquivo único. De lá eles vão para uma **fila** de leitura, e cada um é anunciado com a origem:

> *"No projeto voz-ao-claude: rodei os vinte e sete testes e todos passaram. Tem mais um resumo esperando."*

`Ctrl+Alt+L` entrega o mais recente primeiro e vai descendo. Nada é sobrescrito: se três sessões terminam juntas, os três resumos esperam a sua vez. A fila guarda 20 e descarta os mais antigos além disso.

A origem vem do **nome do arquivo**, não de qual sessão disparou o hook. Por isso qualquer sessão que termine recolhe tudo que estiver parado, sempre com a atribuição certa — nenhum resumo fica preso esperando aquela sessão específica terminar de novo.

Os pedidos de permissão também dizem de quem são: *"O projeto cadeia-sequencial precisa da sua permissão para continuar."*

`/clarisse status` mostra quantos resumos esperam e de quais projetos.

Se o Claude não escrever o resumo, nada é falado — o sistema falha em silêncio, nunca fala lixo.

## Requisitos

- Windows 10/11 com Windows PowerShell 5.1 (já vem no sistema)
- Claude Code instalado
- Python 3 ([python.org](https://www.python.org/downloads/) — o instalador acha sozinho)
- Conexão com internet (a síntese neural é um serviço online)

Reprodução usa `System.Windows.Media.MediaPlayer` do .NET Framework — sem `ffmpeg`, `mpv` ou qualquer player externo.

## Instalação

```powershell
git clone https://github.com/Pujol0100/voz-ao-claude.git
cd voz-ao-claude
powershell -ExecutionPolicy Bypass -File .\instalar.ps1
```

O instalador detecta o Python, instala o `edge-tts`, copia os arquivos para `~/.claude/clarisse`, registra os três hooks (fazendo **backup** do seu `settings.json` e preservando hooks de terceiros), anexa o bloco de instruções ao `CLAUDE.md` e toca uma frase de teste.

Depois, abra `/hooks` uma vez no Claude Code ou reinicie — hooks são lidos na abertura da sessão.

## Comandos

| Comando | O que faz |
|---|---|
| `/clarisse` | Mostra o status |
| `/clarisse ler` | Lê o próximo resumo da fila (mesmo efeito do `Ctrl+Alt+L`) |
| `/clarisse pausar` | Congela a fala; de novo, retoma do mesmo ponto |
| `/clarisse cancelar` | Corta a fala **na hora** |
| `/clarisse atalhos off` | Encerra o escutador de atalhos |
| `/clarisse atalhos on` | Sobe o escutador de atalhos |
| `/clarisse repetir` | Repete a última fala |
| `/clarisse repetir 2` | Repete a penúltima (guarda as 5 últimas) |
| `/clarisse repetir devagar` | Repete mais lenta — para quando o número passou rápido |
| `/clarisse historico` | Lista as 5 últimas falas em texto |
| `/clarisse test` | Toca uma frase de teste |
| `/clarisse voz <nome>` | Troca a voz |
| `/clarisse rapida` / `lenta` | Ajusta a velocidade |
| `/clarisse nao ligar sozinha` | Desativa o autostart |

Frases naturais também funcionam: `/clarisse perdi`, `/clarisse não ouvi`, `/clarisse cala`.

## Vozes disponíveis

| Voz | Perfil |
|---|---|
| `pt-BR-ThalitaMultilingualNeural` | Feminina, multilíngue, mais neutra — **padrão** |
| `pt-BR-FranciscaNeural` | Feminina, brasileira, mais calorosa |
| `pt-BR-AntonioNeural` | Masculina, brasileira |

Lista completa: `python -m edge_tts --list-voices`

## Privacidade — leia antes de usar

> A síntese neural **envia o texto do resumo para servidores da Microsoft** (é o mesmo motor de leitura em voz alta do Edge). O áudio não é gerado localmente.

Isso importa se você usa o Claude Code com dados corporativos ou de clientes. Duas mitigações:

1. O bloco em `docs/INSTRUCOES-CLAUDE.md` já instrui o Claude a **não** colocar credencial, dado pessoal de terceiros, nome de cliente ou valor exato de contrato no resumo falado.
2. Para uso 100% offline, troque o motor pela síntese nativa do Windows (`System.Speech`, voz *Microsoft Maria*). É gratuita e não sai da máquina — mas soa bem mais robótica. A troca fica isolada na função `Invoke-Fala`.

Nada é enviado enquanto a Clarisse estiver pausada.

## Configuração

`~/.claude/clarisse/config.json`:

```json
{
  "enabled": true,
  "autoStart": true,
  "voice": "pt-BR-ThalitaMultilingualNeural",
  "rate": "+12%",
  "volume": "+0%",
  "maxChars": 1800,
  "python": "",
  "atalhos": {
    "ativo": true,
    "ler": "Ctrl+Alt+L",
    "pausar": "Ctrl+Alt+P",
    "cancelar": "Ctrl+Alt+X"
  }
}
```

`python` vazio faz o script detectar o interpretador sozinho. `maxChars` corta falas longas demais — 1800 dá cerca de um minuto e meio de áudio.

As combinações aceitam `Ctrl`, `Alt`, `Shift` e `Win` mais uma tecla (`L`, `F9`, `Up`, `Space`...). Depois de trocar, rode `/clarisse atalhos off` e `/clarisse atalhos on`. Se outro programa já usar a combinação, o Windows recusa e o motivo aparece em `clarisse.log`.

`atalhos.ativo` em `false` impede o escutador de subir junto com a sessão.

## Trocar o nome dela

"Clarisse" é só um nome. Renomeie `comandos/clarisse.md` para o nome que quiser (`/jarvis`, `/sofia`) e ajuste os textos — o motor não depende disso.

## Desinstalar

```powershell
powershell -ExecutionPolicy Bypass -File .\instalar.ps1 -Desinstalar
```

Remove os hooks, o comando e o bloco do `CLAUDE.md`. A pasta `~/.claude/clarisse` é mantida (contém seu config e histórico) para você apagar quando quiser.

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| Não fala nada depois de instalar | Hooks ainda não carregados — abra `/hooks` ou reinicie |
| Fala o teste mas não o resumo | O bloco de instruções não está no `CLAUDE.md`; rode o instalador sem `-SemInstrucoes` |
| Silêncio total e nenhum erro | Veja `~/.claude/clarisse/clarisse.log` |
| `Python nao encontrado` | Preencha o caminho no campo `python` do `config.json` |
| Fala cortada no meio | Alguém apertou `Ctrl+Alt+X` ou rodou `/clarisse pausar` — use `/clarisse continuar` |
| Bipa mas o atalho não faz nada | O escutador caiu ou outro programa tomou a tecla. Veja `/clarisse status` e `clarisse.log`; use `/clarisse ler` enquanto isso |
| Leu o resumo de outro terminal | É a fila fazendo o trabalho dela: ela entrega o mais recente de qualquer sessão, dizendo de qual projeto veio. Aperte de novo para ouvir o próximo |
| Resumo veio sem dizer o projeto | O Claude escreveu no `fala.txt` antigo em vez da caixa do projeto. Funciona, mas sem identificar a origem — reinstale para atualizar o bloco no `CLAUDE.md` |
| Atalho continua ativo com o Claude fechado | É o esperado. `/clarisse atalhos off` encerra o processo residente |
| Bipe não sai | Alguns notebooks silenciam o canal de sistema. Ponha `atalhos.ativo` em `false` e volte ao modo automático, ou confira o mixer do Windows |

## Licença

MIT — veja [LICENSE](LICENSE).
