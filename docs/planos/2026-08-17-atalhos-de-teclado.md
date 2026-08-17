# Atalhos de teclado e resumo com substância — plano de implementação

**Objetivo:** a Clarisse para de falar sozinha ao fim de cada resposta; passa a avisar com um bipe e só fala quando o usuário aperta `Ctrl+Alt+L`, com `Ctrl+Alt+P` para pausar/retomar e `Ctrl+Alt+X` para cancelar — e o texto falado passa a carregar o conteúdo real da resposta, não só "preciso de você".

**Arquitetura:** três peças novas. (1) Um **arquivo de controle** (`controle.txt`) lido em laço pelo processo que reproduz o áudio, permitindo pausa e retomada de verdade no `MediaPlayer` em vez do atual "matar o processo". (2) Um **processo residente oculto** (`atalhos.ps1`) que registra os três atalhos globais via `RegisterHotKey` do Win32 e bombeia mensagens com `GetMessage` — bloqueante, custo zero de CPU. (3) Um **buffer de pendência** (`pendente.txt`): o hook `Stop` move o resumo para lá e emite um bipe, em vez de falar.

Para tornar isso testável, as funções puras de `clarisse.ps1` migram para `clarisse/nucleo.ps1`, carregado por dot-source pelos dois scripts e pelos testes.

**Stack:** Windows PowerShell 5.1, P/Invoke em `user32.dll`, `System.Windows.Media.MediaPlayer`, `edge-tts`, Pester 3.4.

**Validado antes de planejar:** `Console.Beep` funciona neste ambiente; `RegisterHotKey` registrou `Ctrl+Alt+L/P/X` com sucesso (nenhum conflito) e `PeekMessage` respondeu na fila do thread do PowerShell.

---

## Decisões fechadas com o usuário

| Ponto | Decisão |
|---|---|
| Verbosidade | Resumo **com substância**, não leitura literal da tela. `maxChars` sobe de 700 para 1800. |
| Aviso automático | Bipe curto ao terminar a resposta. Pedido de permissão (hook `Notification`) **continua falando por voz**. |
| Teclas | `Ctrl+Alt+L` ler, `Ctrl+Alt+P` pausar/retomar, `Ctrl+Alt+X` cancelar. Configuráveis. |

## Compatibilidade

Os modos existentes (`pausar`, `continuar`, `repetir`, `historico`, `status`, `on`, `off`, `test`) **não mudam de semântica**. `pausar`/`continuar` continuam sendo o silenciamento global da voz. Os três novos modos (`ler`, `alternar-pausa`, `cancelar`) controlam apenas o áudio em curso.

## Estrutura de arquivos

| Arquivo | Responsabilidade |
|---|---|
| `clarisse/nucleo.ps1` — **novo** | Config, caminhos, saneamento de texto, histórico, arquivo de controle, parser de atalho, geração e reprodução do áudio |
| `clarisse/clarisse.ps1` — modificar | Só `param()` + `switch` de modos; carrega o núcleo |
| `clarisse/atalhos.ps1` — **novo** | Processo residente: registra atalhos e despacha ações |
| `clarisse/config.json` — modificar | `maxChars: 1800`, bloco `atalhos` |
| `tests/nucleo.Tests.ps1` — **novo** | Pester sobre as funções puras do núcleo |
| `docs/INSTRUCOES-CLAUDE.md` — modificar | Regra do resumo com substância |
| `comandos/clarisse.md`, `README.md`, `instalar.ps1` — modificar | Documentar e instalar o novo fluxo |

---

## Task 1: Extrair o núcleo (refatoração sem mudança de comportamento)

**Arquivos:** criar `clarisse/nucleo.ps1`; modificar `clarisse/clarisse.ps1`

- [ ] **Passo 1** — Criar `clarisse/nucleo.ps1` movendo de `clarisse.ps1` (linhas 31–250), sem alterar corpo: os `$Root/$ConfigPath/...`, `Write-Log`, `Get-Config`, `Save-Config`, `Get-PythonInvocacao`, `ConvertTo-Falavel`, `Get-ItensHistorico`, `Add-Historico`, `Get-RateMaisLento`, `Stop-Reproducao`, `Invoke-Fala`, `Start-FalaAssincrona`.

  A resolução de raiz muda para funcionar sob dot-source e permitir override nos testes:

  ```powershell
  if (-not $Script:ClarisseRoot) { $Script:ClarisseRoot = $PSScriptRoot }
  $Root = $Script:ClarisseRoot
  ```

  Em `Start-FalaAssincrona`, trocar `$MyInvocation.MyCommand.Path` por `Join-Path $Root 'clarisse.ps1'` (dentro do núcleo o `$MyInvocation` aponta para o núcleo, não para o script chamador).

- [ ] **Passo 2** — Em `clarisse.ps1`, substituir o corpo removido por `. (Join-Path $PSScriptRoot 'nucleo.ps1')` logo após o `param()` e o `$ErrorActionPreference`.

- [ ] **Passo 3** — Verificar que nada quebrou: `powershell -File clarisse/clarisse.ps1 -Mode status` deve imprimir a linha de status; `-Mode test` deve falar.

- [ ] **Passo 4** — Commit: `refactor: extrai funcoes compartilhadas para nucleo.ps1`

---

## Task 2: Arquivo de controle (pausa real, retomada e cancelamento)

**Arquivos:** `clarisse/nucleo.ps1`; teste `tests/nucleo.Tests.ps1`

- [ ] **Passo 1: teste que falha**

  ```powershell
  Describe 'controle de reproducao' {
      It 'devolve tocar quando nao ha arquivo de controle' {
          Set-Controle 'tocar'; Remove-Item $ControlePath -Force -ErrorAction SilentlyContinue
          Get-Controle | Should Be 'tocar'
      }
      It 'guarda e devolve o estado gravado' {
          Set-Controle 'pausado'; Get-Controle | Should Be 'pausado'
          Set-Controle 'cancelar'; Get-Controle | Should Be 'cancelar'
      }
      It 'ignora valor invalido e cai em tocar' {
          [System.IO.File]::WriteAllText($ControlePath, 'lixo')
          Get-Controle | Should Be 'tocar'
      }
      It 'alterna tocar para pausado e de volta' {
          Set-Controle 'tocar';   Switch-Pausa | Should Be 'pausado'
          Switch-Pausa | Should Be 'tocar'
      }
  }
  ```

- [ ] **Passo 2** — Rodar `Invoke-Pester tests/nucleo.Tests.ps1`. Esperado: FAIL, `Set-Controle` não reconhecido.

- [ ] **Passo 3: implementar no núcleo**

  ```powershell
  $ControlePath = Join-Path $Root 'controle.txt'

  function Get-Controle {
      if (-not (Test-Path $ControlePath)) { return 'tocar' }
      try { $v = ([System.IO.File]::ReadAllText($ControlePath)).Trim().ToLower() } catch { return 'tocar' }
      if ($v -in @('tocar', 'pausado', 'cancelar')) { return $v }
      return 'tocar'
  }

  function Set-Controle([string]$estado) {
      [System.IO.File]::WriteAllText($ControlePath, $estado, $Utf8SemBom)
  }

  function Switch-Pausa {
      $novo = if ((Get-Controle) -eq 'pausado') { 'tocar' } else { 'pausado' }
      Set-Controle $novo
      return $novo
  }
  ```

- [ ] **Passo 4** — Rodar os testes. Esperado: 4 passando.

- [ ] **Passo 5: trocar o `Start-Sleep` cego pelo laço que obedece ao controle**

  Em `Invoke-Fala`, substituir o trecho `$player.Play(); Start-Sleep ...; $player.Stop()` por:

  ```powershell
  Set-Controle 'tocar'
  $player.Play()
  $pausado = $false
  $limite  = [datetime]::Now.AddMinutes(20)   # trava de seguranca: pausa esquecida nao prende o mutex pra sempre
  while ($player.Position.TotalSeconds -lt $dur -and [datetime]::Now -lt $limite) {
      switch (Get-Controle) {
          'cancelar' { $player.Stop(); $player.Close(); Set-Controle 'tocar'; return }
          'pausado'  { if (-not $pausado) { $player.Pause(); $pausado = $true } }
          'tocar'    { if ($pausado)      { $player.Play();  $pausado = $false } }
      }
      Start-Sleep -Milliseconds 120
  }
  $player.Stop()
  $player.Close()
  Set-Controle 'tocar'
  ```

  `Set-Controle 'tocar'` no início é o que impede uma fala nova de já nascer cancelada.

- [ ] **Passo 6: verificação manual** — rodar `-Mode test` e, durante a fala, executar `-Mode alternar-pausa` (Task 3) em outro terminal: o áudio deve congelar e voltar do mesmo ponto, não do começo.

- [ ] **Passo 7** — Commit: `feat: pausa e retomada reais via arquivo de controle`

---

## Task 3: Novos modos `ler`, `alternar-pausa` e `cancelar`

**Arquivos:** `clarisse/nucleo.ps1`, `clarisse/clarisse.ps1`

- [ ] **Passo 1: teste que falha**

  ```powershell
  Describe 'pendencia de leitura' {
      It 'guarda o resumo como pendente e informa que ha algo' {
          Set-Pendente 'Rodei os testes. Passaram os doze.'
          Test-Pendente | Should Be $true
      }
      It 'entrega e consome a pendencia' {
          Set-Pendente 'texto pendente'
          Read-Pendente | Should Be 'texto pendente'
          Test-Pendente | Should Be $false
      }
      It 'devolve vazio quando nao ha pendencia' {
          Remove-Item $PendentePath -Force -ErrorAction SilentlyContinue
          Read-Pendente | Should BeNullOrEmpty
      }
  }
  ```

- [ ] **Passo 2** — Rodar. Esperado: FAIL, `Set-Pendente` não reconhecido.

- [ ] **Passo 3: implementar no núcleo**

  ```powershell
  $PendentePath = Join-Path $Root 'pendente.txt'

  function Set-Pendente([string]$texto) {
      [System.IO.File]::WriteAllText($PendentePath, $texto, $Utf8SemBom)
  }

  function Test-Pendente {
      if (-not (Test-Path $PendentePath)) { return $false }
      return -not [string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($PendentePath))
  }

  function Read-Pendente {
      if (-not (Test-Path $PendentePath)) { return '' }
      $t = [System.IO.File]::ReadAllText($PendentePath, [System.Text.Encoding]::UTF8)
      Remove-Item $PendentePath -Force -ErrorAction SilentlyContinue
      return $t
  }

  # Bipe curto de "tem coisa para ouvir". Silencioso se o hardware recusar.
  function Send-Bipe {
      try { [console]::Beep(880, 120); [console]::Beep(1175, 160) } catch { }
  }
  ```

- [ ] **Passo 4** — Rodar os testes. Esperado: 7 passando (4 da Task 2 + 3).

- [ ] **Passo 5: registrar os modos** — em `clarisse.ps1`, acrescentar ao `ValidateSet` os valores `'ler'`, `'alternar-pausa'`, `'cancelar'` e ao `switch`:

  ```powershell
  'ler' {
      $texto = Read-Pendente
      if ([string]::IsNullOrWhiteSpace($texto)) {
          Start-FalaAssincrona 'Nada novo para ler.'
          Write-Output 'Clarisse: nada pendente'
          break
      }
      Start-FalaAssincrona $texto
      Write-Output 'Clarisse: lendo o resumo pendente'
  }

  'alternar-pausa' {
      $novo = Switch-Pausa
      if ($novo -eq 'pausado') { Write-Output 'Clarisse: fala pausada' }
      else                     { Write-Output 'Clarisse: fala retomada' }
  }

  'cancelar' {
      Set-Controle 'cancelar'
      Start-Sleep -Milliseconds 350
      # O laco de reproducao ja deve ter saido. Se a fala ainda estava sendo
      # gerada pelo edge-tts (chamada bloqueante), so o kill resolve.
      Stop-Reproducao | Out-Null
      Set-Controle 'tocar'
      Write-Output 'Clarisse: fala cancelada'
  }
  ```

- [ ] **Passo 6** — Verificar: `-Mode ler` sem pendência deve imprimir `Clarisse: nada pendente`.

- [ ] **Passo 7** — Commit: `feat: modos ler, alternar-pausa e cancelar`

---

## Task 4: Hook `Stop` deixa de falar — passa a enfileirar e bipar

**Arquivos:** `clarisse/clarisse.ps1`

- [ ] **Passo 1** — Substituir o bloco `'stop'` por:

  ```powershell
  'stop' {
      if (-not $cfg.enabled) { exit 0 }
      if (Test-Path $FalaPath) {
          $resumo = Get-Content $FalaPath -Raw -Encoding utf8
          Remove-Item $FalaPath -Force -ErrorAction SilentlyContinue
          if (-not [string]::IsNullOrWhiteSpace($resumo)) {
              Set-Pendente $resumo
              Add-Historico (ConvertTo-Falavel $resumo $cfg.maxChars)
              Send-Bipe
          }
      }
  }
  ```

  O histórico passa a ser alimentado aqui (e não só na hora de falar) para que `/clarisse repetir` funcione mesmo em resumo que o usuário nunca mandou ler.

- [ ] **Passo 2** — Em `Invoke-Fala`, o `-PularHistorico` já existe; o modo `ler` deve usar `Start-FalaAssincrona`, que grava histórico de novo. Evitar duplicata: em `Read-Pendente` o texto já foi historiado no `stop`, então `'ler'` chama `Start-FalaAssincrona $texto -PularHistorico`. Adicionar o switch a `Start-FalaAssincrona`, gravando um marcador no nome do arquivo pendente:

  ```powershell
  function Start-FalaAssincrona([string]$texto, [switch]$PularHistorico) {
      if ([string]::IsNullOrWhiteSpace($texto)) { return }
      if (-not (Test-Path $PendDir)) { New-Item -ItemType Directory -Force $PendDir | Out-Null }
      $sufixo = if ($PularHistorico) { '.nohist' } else { '' }
      $arq = Join-Path $PendDir ("$([guid]::NewGuid().ToString('N'))$sufixo.txt")
      ...
  }
  ```

  E no modo `speak`:

  ```powershell
  $semHist = $File -like '*.nohist.txt'
  if ($semHist) { Invoke-Fala $conteudo -RespeitaEnabled -PularHistorico }
  else          { Invoke-Fala $conteudo -RespeitaEnabled }
  ```

- [ ] **Passo 3** — Verificação manual ponta a ponta: escrever texto em `fala.txt`, rodar `-Mode stop` → deve **bipar e não falar**; `-Mode ler` → deve falar.

- [ ] **Passo 4** — Commit: `feat: hook Stop enfileira e bipa em vez de falar`

---

## Task 5: Parser de atalho

**Arquivos:** `clarisse/nucleo.ps1`, `tests/nucleo.Tests.ps1`

- [ ] **Passo 1: teste que falha**

  ```powershell
  Describe 'ConvertTo-CodigoAtalho' {
      It 'traduz Ctrl+Alt+L' {
          $r = ConvertTo-CodigoAtalho 'Ctrl+Alt+L'
          $r.vk  | Should Be 76
          $r.mod | Should Be (2 -bor 1 -bor 0x4000)
      }
      It 'aceita nomes por extenso e caixa alta ou baixa' {
          (ConvertTo-CodigoAtalho 'control+shift+up').vk  | Should Be 38
          (ConvertTo-CodigoAtalho 'control+shift+up').mod | Should Be (2 -bor 4 -bor 0x4000)
      }
      It 'aceita a tecla Windows' {
          (ConvertTo-CodigoAtalho 'Win+Alt+X').mod | Should Be (8 -bor 1 -bor 0x4000)
      }
      It 'devolve nulo sem modificador' { ConvertTo-CodigoAtalho 'L' | Should BeNullOrEmpty }
      It 'devolve nulo com tecla inexistente' { ConvertTo-CodigoAtalho 'Ctrl+Alt+Batata' | Should BeNullOrEmpty }
      It 'devolve nulo para entrada vazia' { ConvertTo-CodigoAtalho '' | Should BeNullOrEmpty }
  }
  ```

- [ ] **Passo 2** — Rodar. Esperado: FAIL, comando não reconhecido.

- [ ] **Passo 3: implementar no núcleo**

  ```powershell
  # Traduz "Ctrl+Alt+L" para os codigos que o RegisterHotKey do Win32 espera.
  # MOD_ALT=1 MOD_CONTROL=2 MOD_SHIFT=4 MOD_WIN=8 MOD_NOREPEAT=0x4000
  function ConvertTo-CodigoAtalho([string]$combinacao) {
      if ([string]::IsNullOrWhiteSpace($combinacao)) { return $null }
      Add-Type -AssemblyName System.Windows.Forms
      $mods = @{ 'ctrl' = 2; 'control' = 2; 'alt' = 1; 'shift' = 4; 'win' = 8; 'windows' = 8 }
      $mod = 0
      $tecla = $null
      foreach ($parte in ($combinacao -split '\+')) {
          $p = $parte.Trim().ToLower()
          if (-not $p) { continue }
          if ($mods.ContainsKey($p)) { $mod = $mod -bor $mods[$p] }
          elseif ($tecla) { return $null }
          else { $tecla = $p }
      }
      if ($mod -eq 0 -or -not $tecla) { return $null }
      try { $vk = [int][System.Windows.Forms.Keys][Enum]::Parse([System.Windows.Forms.Keys], $tecla, $true) }
      catch { return $null }
      return @{ mod = ($mod -bor 0x4000); vk = $vk }
  }
  ```

- [ ] **Passo 4** — Rodar os testes. Esperado: 13 passando.

- [ ] **Passo 5** — Commit: `feat: parser de combinacao de teclas`

---

## Task 6: Processo residente dos atalhos

**Arquivos:** criar `clarisse/atalhos.ps1`; modificar `clarisse/config.json`, `clarisse/clarisse.ps1`

- [ ] **Passo 1: config** — acrescentar a `config.json` e ao padrão de `Get-Config`:

  ```json
  "maxChars": 1800,
  "atalhos": {
    "ativo": true,
    "ler": "Ctrl+Alt+L",
    "pausar": "Ctrl+Alt+P",
    "cancelar": "Ctrl+Alt+X"
  }
  ```

- [ ] **Passo 2: criar `clarisse/atalhos.ps1`**

  ```powershell
  #Requires -Version 5.1
  <#
      Escuta os atalhos globais da Clarisse e despacha as acoes.
      Roda oculto, uma instancia por maquina. Encerre com: clarisse.ps1 -Mode atalhos-off
  #>
  $ErrorActionPreference = 'Stop'
  . (Join-Path $PSScriptRoot 'nucleo.ps1')

  $AtalhosPid = Join-Path $Root 'atalhos.pid'

  Add-Type -TypeDefinition @'
  using System;
  using System.Runtime.InteropServices;
  public static class ClarisseHotkeys {
      [DllImport("user32.dll", SetLastError = true)]
      public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
      [DllImport("user32.dll", SetLastError = true)]
      public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
      [StructLayout(LayoutKind.Sequential)]
      public struct MSG {
          public IntPtr hwnd; public uint message; public IntPtr wParam;
          public IntPtr lParam; public uint time; public int pt_x; public int pt_y;
      }
      [DllImport("user32.dll")]
      public static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);
  }
  '@ -Language CSharp

  $cfg = Get-Config
  $mapa = @(
      @{ id = 1; combo = $cfg.atalhos.ler;      acao = 'ler' }
      @{ id = 2; combo = $cfg.atalhos.pausar;   acao = 'pausa' }
      @{ id = 3; combo = $cfg.atalhos.cancelar; acao = 'cancelar' }
  )

  $registrados = @()
  foreach ($item in $mapa) {
      $cod = ConvertTo-CodigoAtalho $item.combo
      if (-not $cod) { Write-Log "atalho invalido ignorado: $($item.combo)"; continue }
      if ([ClarisseHotkeys]::RegisterHotKey([IntPtr]::Zero, $item.id, $cod.mod, $cod.vk)) {
          $registrados += $item
      } else {
          Write-Log "atalho $($item.combo) ja esta em uso por outro programa"
      }
  }
  if ($registrados.Count -eq 0) { Write-Log 'nenhum atalho registrado - encerrando'; exit 1 }

  [System.IO.File]::WriteAllText($AtalhosPid, "$PID", $Utf8SemBom)
  Write-Log "atalhos ativos: $(($registrados | ForEach-Object { $_.combo }) -join ', ')"

  try {
      $msg = New-Object ClarisseHotkeys+MSG
      # GetMessage bloqueia ate chegar mensagem: laco sem consumo de CPU.
      while ([ClarisseHotkeys]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0) -gt 0) {
          if ($msg.message -ne 0x0312) { continue }   # WM_HOTKEY
          switch ($msg.wParam.ToInt32()) {
              1 {
                  $texto = Read-Pendente
                  if ([string]::IsNullOrWhiteSpace($texto)) { Start-FalaAssincrona 'Nada novo para ler.' -PularHistorico }
                  else { Start-FalaAssincrona $texto -PularHistorico }
              }
              2 { Switch-Pausa | Out-Null }
              3 { Set-Controle 'cancelar'; Start-Sleep -Milliseconds 350; Stop-Reproducao | Out-Null; Set-Controle 'tocar' }
          }
      }
  } finally {
      foreach ($item in $registrados) { [void][ClarisseHotkeys]::UnregisterHotKey([IntPtr]::Zero, $item.id) }
      Remove-Item $AtalhosPid -Force -ErrorAction SilentlyContinue
  }
  ```

  Ler e cancelar rodam direto no laço: são escrita de arquivo, milissegundos. A fala em si já sai num processo separado via `Start-FalaAssincrona`, então o laço nunca fica preso.

- [ ] **Passo 3: modos de ciclo de vida em `clarisse.ps1`** — acrescentar `'atalhos-on'`, `'atalhos-off'` ao `ValidateSet` e ao `switch`:

  ```powershell
  'atalhos-on' {
      if (Test-AtalhosAtivos) { Write-Output 'Clarisse: atalhos ja estavam ativos'; break }
      Start-Process -FilePath 'powershell.exe' `
          -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'atalhos.ps1')`"" `
          -WindowStyle Hidden | Out-Null
      Write-Output "Clarisse: atalhos ativos - $($cfg.atalhos.ler) le, $($cfg.atalhos.pausar) pausa, $($cfg.atalhos.cancelar) cancela"
  }

  'atalhos-off' {
      if (-not (Test-AtalhosAtivos)) { Write-Output 'Clarisse: atalhos ja estavam desligados'; break }
      Stop-Process -Id ([int](Get-Content $AtalhosPidPath -Raw).Trim()) -Force -ErrorAction SilentlyContinue
      Remove-Item $AtalhosPidPath -Force -ErrorAction SilentlyContinue
      Write-Output 'Clarisse: atalhos desligados'
  }
  ```

  No núcleo:

  ```powershell
  $AtalhosPidPath = Join-Path $Root 'atalhos.pid'

  function Test-AtalhosAtivos {
      if (-not (Test-Path $AtalhosPidPath)) { return $false }
      try { $id = [int](Get-Content $AtalhosPidPath -Raw).Trim() } catch { return $false }
      $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($proc -and $proc.ProcessName -like 'powershell*') { return $true }
      Remove-Item $AtalhosPidPath -Force -ErrorAction SilentlyContinue
      return $false
  }
  ```

- [ ] **Passo 4: subir junto com a sessão** — no modo `autostart`, depois do bloco existente:

  ```powershell
  if ($cfg.atalhos -and $cfg.atalhos.ativo -and -not (Test-AtalhosAtivos)) {
      Start-Process -FilePath 'powershell.exe' `
          -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'atalhos.ps1')`"" `
          -WindowStyle Hidden | Out-Null
  }
  ```

- [ ] **Passo 5: `status` mostra os atalhos** — acrescentar à linha de status: `| atalhos: ATIVOS (Ctrl+Alt+L / Ctrl+Alt+P / Ctrl+Alt+X)` ou `DESLIGADOS`.

- [ ] **Passo 6: verificação manual** — rodar `-Mode atalhos-on`, apertar `Ctrl+Alt+L` com pendência gravada (deve falar), `Ctrl+Alt+P` durante a fala (deve congelar), de novo (deve voltar do mesmo ponto), `Ctrl+Alt+X` (deve calar na hora). Depois `-Mode atalhos-off` e confirmar que as teclas não fazem mais nada.

- [ ] **Passo 7** — Commit: `feat: atalhos globais de ler, pausar e cancelar`

---

## Task 7: Resumo com substância

**Arquivos:** `docs/INSTRUCOES-CLAUDE.md`, `clarisse/config.json`

- [ ] **Passo 1** — Reescrever `docs/INSTRUCOES-CLAUDE.md`. Mudanças de conteúdo:
  - `fala.txt` continua sendo o canal, mas o texto passa a ser lido **sob comando**, então pode ser mais longo: 4 a 8 frases, limite prático ~1500 caracteres.
  - Regra dura contra resumo oco: **é proibido** dizer "encontrei um problema", "preciso da sua decisão", "há uma pendência" sem dizer, na mesma frase, **qual**. Toda menção a algo que exige ação tem que vir com o conteúdo da ação.
  - Continua obrigatório repetir todo valor em reais, data e quantidade por extenso.
  - Continua proibido ler caminho de arquivo, comando, bloco de código, URL e hash.
  - Retirar a linha "Não repita literalmente o texto da tela" — trocar por "diga as conclusões e os achados, não a narrativa do que você fez".

- [ ] **Passo 2** — `maxChars` para `1800` no `config.json` e no padrão de `Get-Config`.

- [ ] **Passo 3** — Aplicar o mesmo bloco no `~/.claude/CLAUDE.md` do usuário. **Atenção:** o bloco instalado hoje está **sem os marcadores** `<!-- clarisse:inicio -->` / `<!-- clarisse:fim -->`, então o instalador não o encontra e anexaria uma segunda cópia. Remover o bloco antigo à mão e reinstalar.

- [ ] **Passo 4** — Commit: `feat: resumo falado passa a carregar o conteudo, nao so o aviso`

---

## Task 8: Instalador, comando e README

**Arquivos:** `instalar.ps1`, `comandos/clarisse.md`, `README.md`

- [ ] **Passo 1: `instalar.ps1`** — copiar `clarisse/nucleo.ps1` e `clarisse/atalhos.ps1` junto com `clarisse.ps1`; migrar config já existente acrescentando `atalhos` e subindo `maxChars` se ainda estiver em 700; no desinstalar, chamar `-Mode atalhos-off` antes de remover; acrescentar `pendente.txt`, `controle.txt` e `atalhos.pid` ao `.gitignore`.

- [ ] **Passo 2: `comandos/clarisse.md`** — novas linhas na tabela: `ler` → `-Mode ler`; `cancelar` → `-Mode cancelar`; `atalhos on|off` → `-Mode atalhos-on` / `-Mode atalhos-off`; e a tabela de config ganha `atalho ler <combinacao>` etc.

- [ ] **Passo 3: `README.md`** — atualizar o diagrama de fluxo (bipe + atalho, não fala automática), a tabela de comandos, e revisar a seção "Por que isso existe": o texto atual defende resumo curtíssimo; passa a defender resumo **substantivo sob demanda**. Documentar que os atalhos exigem um processo residente e como desligá-lo.

- [ ] **Passo 4** — Commit: `docs: atalhos de teclado e novo fluxo de leitura`

---

## Task 9: Fechamento

- [ ] **Passo 1** — `Invoke-Pester tests/` — esperado 13 passando, 0 falhando.
- [ ] **Passo 2** — Teste de ponta a ponta numa sessão real do Claude Code: resposta termina → bipe, sem voz; `Ctrl+Alt+L` fala; `Ctrl+Alt+P` pausa e retoma; `Ctrl+Alt+X` cancela; pedido de permissão ainda fala sozinho.
- [ ] **Passo 3** — Seguir `finishing-a-development-branch` para PR/merge.

---

## Riscos conhecidos

| Risco | Mitigação |
|---|---|
| Outro programa já usa `Ctrl+Alt+L` | `RegisterHotKey` falha e o log registra qual combinação foi recusada; as outras continuam funcionando. Trocável no config. |
| Processo residente sobrevive ao fechamento do Claude Code | É intencional (os atalhos precisam funcionar com o terminal fora de foco). `-Mode atalhos-off` encerra; `status` mostra se está de pé. |
| Pausa esquecida prende o mutex e trava as próximas falas | Trava de 20 minutos no laço de reprodução. |
| Resumo de 1800 caracteres vira 1min30 de áudio | É o ponto: agora só toca sob comando, e `Ctrl+Alt+X` corta. |
| Pester 3.4 (antigo) — sintaxe `Should Be`, não `Should -Be` | Testes escritos na sintaxe 3.x. |
