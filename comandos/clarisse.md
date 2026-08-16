---
description: Controla a voz da Clarisse - pausar, continuar, repetir o que foi falado, trocar voz
argument-hint: "pausar | continuar | repetir [n] | repetir devagar | historico | status | test | on | off | voz <nome> | rapida | lenta"
allowed-tools: PowerShell, Read, Edit
---

Controle da voz Clarisse. Argumento recebido: `$ARGUMENTS`

Script: `$env:USERPROFILE\.claude\clarisse\clarisse.ps1`
Config: `$env:USERPROFILE\.claude\clarisse\config.json`

Chame sempre como `& "$env:USERPROFILE\.claude\clarisse\clarisse.ps1" -Mode <modo>` e responda com **uma linha apenas** (a saida do script ja e a resposta).

| Argumento | Modo / acao |
|---|---|
| `pausar`, `pausa`, `para`, `silencio`, `cala` | `-Mode pausar` — corta o audio em curso na hora e silencia |
| `continuar`, `continua`, `volta`, `retomar` | `-Mode continuar` |
| `repetir`, `repete`, `de novo`, `nao ouvi`, `perdi` | `-Mode repetir` — repete a ultima fala |
| `repetir 2`, `repetir 3` (ate 5) | `-Mode repetir -Indice N` — N=1 e a mais recente |
| `repetir devagar`, `mais devagar` | `-Mode repetir -Devagar` |
| `repetir 2 devagar` | `-Mode repetir -Indice 2 -Devagar` |
| `historico`, `o que voce falou` | `-Mode historico` — lista as ultimas 5 falas |
| `status` ou vazio | `-Mode status` |
| `test`, `teste` | `-Mode test` |
| `on`, `off` | `-Mode on` / `-Mode off` |

Ajustes que exigem editar o `config.json` e depois rodar `-Mode test`:

| Argumento | Alteracao no config.json |
|---|---|
| `voz <nome>` | Campo `voice`. Opcoes pt-BR: `pt-BR-ThalitaMultilingualNeural` (feminina, padrao), `pt-BR-FranciscaNeural` (feminina), `pt-BR-AntonioNeural` (masculina) |
| `rapida` | `rate` +10 pontos percentuais (teto `+50%`) |
| `lenta` | `rate` -10 pontos percentuais (piso `-30%`) |
| `nao ligar sozinha` | `autoStart` para `false` |
| `ligar sozinha` | `autoStart` para `true` |

Se o argumento nao corresponder a nada acima, rode `-Mode status` e liste as opcoes validas em uma linha.

Nao escreva resumo em `fala.txt` para este comando — o proprio script ja da o retorno falado ou impresso.
