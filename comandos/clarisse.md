---
description: Controla a voz da Clarisse - ler, pausar, cancelar, atalhos, repetir, trocar voz
argument-hint: "ler | pausar | cancelar | atalhos on|off | repetir [n] [devagar] | historico | status | test | on | off | voz <nome> | rapida | lenta"
allowed-tools: PowerShell, Read, Edit
---

Controle da voz Clarisse. Argumento recebido: `$ARGUMENTS`

Script: `$env:USERPROFILE\.claude\clarisse\clarisse.ps1`
Config: `$env:USERPROFILE\.claude\clarisse\config.json`

Chame sempre como `& "$env:USERPROFILE\.claude\clarisse\clarisse.ps1" -Mode <modo>` e responda com **uma linha apenas** (a saida do script ja e a resposta).

O normal e usar as teclas, nao este comando: `Ctrl+Alt+L` le, `Ctrl+Alt+P` pausa e retoma, `Ctrl+Alt+X` cancela. Este comando existe para quando o atalho nao esta disponivel ou para ajustar configuracao.

| Argumento | Modo / acao |
|---|---|
| `ler`, `le`, `fala`, `o que voce fez` | `-Mode ler` — fala o resumo que esta na fila (mesmo efeito do Ctrl+Alt+L) |
| `pausar`, `pausa`, `espera` | `-Mode alternar-pausa` — congela a fala; de novo, retoma do mesmo ponto |
| `retomar`, `continua a fala` | `-Mode alternar-pausa` |
| `cancelar`, `cala`, `para`, `silencio` | `-Mode cancelar` — corta a fala em curso na hora |
| `atalhos on`, `ligar atalhos` | `-Mode atalhos-on` |
| `atalhos off`, `desligar atalhos` | `-Mode atalhos-off` |
| `repetir`, `repete`, `de novo`, `nao ouvi`, `perdi` | `-Mode repetir` — repete a ultima fala |
| `repetir 2`, `repetir 3` (ate 5) | `-Mode repetir -Indice N` — N=1 e a mais recente |
| `repetir devagar`, `mais devagar` | `-Mode repetir -Devagar` |
| `repetir 2 devagar` | `-Mode repetir -Indice 2 -Devagar` |
| `historico`, `o que voce falou` | `-Mode historico` — lista as ultimas 5 falas |
| `status` ou vazio | `-Mode status` |
| `test`, `teste` | `-Mode test` |
| `on`, `off` | `-Mode on` / `-Mode off` — liga ou desliga a voz por completo |
| `silenciar tudo` | `-Mode pausar` — desliga a voz e corta o que estiver tocando |

Ajustes que exigem editar o `config.json` e depois rodar `-Mode test`:

| Argumento | Alteracao no config.json |
|---|---|
| `voz <nome>` | Campo `voice`. Opcoes pt-BR: `pt-BR-ThalitaMultilingualNeural` (feminina, padrao), `pt-BR-FranciscaNeural` (feminina), `pt-BR-AntonioNeural` (masculina) |
| `rapida` | `rate` +10 pontos percentuais (teto `+50%`) |
| `lenta` | `rate` -10 pontos percentuais (piso `-30%`) |
| `nao ligar sozinha` | `autoStart` para `false` |
| `ligar sozinha` | `autoStart` para `true` |
| `atalho ler <combinacao>` | `atalhos.ler`, ex. `Ctrl+Shift+Up`. Depois rode `-Mode atalhos-off` e `-Mode atalhos-on` |
| `atalho pausar <combinacao>` | `atalhos.pausar`, mesmo procedimento |
| `atalho cancelar <combinacao>` | `atalhos.cancelar`, mesmo procedimento |
| `resumo mais longo` / `mais curto` | `maxChars`, entre 700 e 4000 |

Se o argumento nao corresponder a nada acima, rode `-Mode status` e liste as opcoes validas em uma linha.

Nao escreva resumo em `fala.txt` para este comando — o proprio script ja da o retorno falado ou impresso.
