# voz-ao-claude

**Clarisse** dá voz ao [Claude Code](https://claude.com/claude-code) no Windows. Quando o Claude termina uma resposta, ela fala em voz alta o que foi feito, os números que apareceram e o que ficou pendente.

O Claude Code já **ouve** você (voice mode). Este projeto fecha o outro lado: ele passa a **responder falando**.

## Por que isso existe

Nasceu de um problema concreto de acessibilidade: dificuldade de concentração para ler respostas longas na tela, levando a erros por não ler tudo — um valor conferido errado, um aviso ignorado, uma pendência que passou batido.

A solução não é ler a resposta inteira em voz alta. Isso é pior: TTS fala ~150 palavras/min e ninguém aguenta ouvir caminho de arquivo e bloco de código. A Clarisse fala **só o que não pode passar**:

- o resultado do que acabou de rodar;
- o que ainda falta ou precisa da sua decisão;
- valores, prazos e datas, ditos devagar;
- avisos antes de qualquer ação irreversível;
- quando o Claude para esperando sua permissão.

O detalhe continua na tela. O áudio é o resumo.

## Como funciona

Uma skill não produz som — skill é só texto de instrução. Quem produz som são **hooks**, que o Claude Code executa sozinho em pontos do ciclo de vida.

```
você fala  ──►  Claude Code (voice mode)  ──►  Claude trabalha
                                                     │
                                    escreve o resumo em fala.txt
                                                     │
                                          hook Stop dispara
                                                     │
                                    edge-tts gera o áudio ──► 🔊 Clarisse fala
```

| Peça | Papel |
|---|---|
| `clarisse/clarisse.ps1` | Motor: gera o áudio e reproduz |
| Hook `Stop` | Fala o resumo quando o Claude termina |
| Hook `Notification` | Fala quando o Claude para pedindo permissão |
| Hook `SessionStart` | Religa a voz a cada sessão nova |
| `comandos/clarisse.md` | Slash command `/clarisse` |
| `docs/INSTRUCOES-CLAUDE.md` | Bloco anexado ao seu `CLAUDE.md` que instrui o Claude a escrever o resumo |

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
| `/clarisse pausar` | Corta a fala **na hora** e silencia |
| `/clarisse continuar` | Volta a falar |
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
  "maxChars": 700,
  "python": ""
}
```

`python` vazio faz o script detectar o interpretador sozinho. `maxChars` corta falas longas demais.

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
| Fala cortada no meio | Alguém rodou `/clarisse pausar` — use `/clarisse continuar` |

## Licença

MIT — veja [LICENSE](LICENSE).
