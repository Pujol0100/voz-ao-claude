#Requires -Version 5.1
<#
    Clarisse - voz para o Claude Code no Windows.
    Gera fala neural (edge-tts) e reproduz sem depender de player externo.

    A partir da versao com atalhos, o fim de uma resposta nao fala sozinho:
    o resumo entra na fila e a Clarisse so bipa. Voce manda ler quando quiser.

    Modos:
      say            -Text "..."   fala o texto informado
      speak          -File "..."   fala o conteudo de um arquivo (uso interno, background)
      stop                         hook Stop: enfileira o resumo de fala.txt e bipa
      notify                       hook Notification: fala a mensagem recebida no stdin
      autostart                    hook SessionStart: religa a voz e sobe os atalhos
      ler                          fala o resumo que esta na fila
      alternar-pausa               pausa a fala em curso, ou retoma do mesmo ponto
      cancelar                     corta a fala em curso na hora
      atalhos-on / atalhos-off     liga ou desliga o escutador de atalhos globais
      on / off / toggle            liga, desliga ou alterna a voz
      pausar                       silencia a voz por completo (e corta o que estiver tocando)
      continuar                    volta a falar
      repetir        -Indice N     repete a N-esima fala mais recente (1 = ultima)
                     -Devagar      repete mais lentamente
      historico                    lista as ultimas falas
      status                       mostra o estado atual
      test                         fala uma frase de teste
#>
param(
    [ValidateSet('say', 'speak', 'stop', 'notify', 'autostart', 'ler', 'proximo', 'alternar-pausa', 'cancelar',
                 'atalhos-on', 'atalhos-off', 'on', 'off', 'toggle',
                 'pausar', 'continuar', 'repetir', 'historico', 'status', 'test')]
    [string]$Mode = 'say',
    [string]$Text = '',
    [string]$Projeto = '',
    [string]$File = '',
    [int]$Indice = 1,
    [switch]$Devagar
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'nucleo.ps1')

$cfg = Get-Config

switch ($Mode) {

    'autostart' {
        # Hook SessionStart: garante que a voz volta ligada a cada sessao nova
        # e que o escutador de atalhos esta de pe.
        if ($cfg.PSObject.Properties.Name -notcontains 'autoStart') {
            $cfg | Add-Member -NotePropertyName autoStart -NotePropertyValue $true -Force
        }
        if ($cfg.autoStart -and -not $cfg.enabled) {
            $cfg.enabled = $true
            Save-Config $cfg
        }
        if ($cfg.atalhos -and $cfg.atalhos.ativo -and -not (Test-AtalhosAtivos)) {
            Start-Atalhos
        }
    }

    'on' {
        $cfg.enabled = $true; Save-Config $cfg
        Invoke-Fala 'Voz ligada.' -PularHistorico
        Write-Output 'Clarisse: LIGADA'
    }

    'off' {
        Invoke-Fala 'Voz desligada.' -PularHistorico
        $cfg.enabled = $false; Save-Config $cfg
        Write-Output 'Clarisse: DESLIGADA'
    }

    'toggle' {
        if ($cfg.enabled) {
            Invoke-Fala 'Voz desligada.' -PularHistorico
            $cfg.enabled = $false; Save-Config $cfg
            Write-Output 'Clarisse: DESLIGADA'
        } else {
            $cfg.enabled = $true; Save-Config $cfg
            Invoke-Fala 'Voz ligada.' -PularHistorico
            Write-Output 'Clarisse: LIGADA'
        }
    }

    'ler' {
        # Ler um resumo tem tres caminhos: o projeto veio pelo comando, o projeto
        # ja esta escolhido no modo selecao, ou ainda e preciso decidir qual ler.

        if ($Projeto) {
            $item = Read-Pendente -Projeto $Projeto
            if (-not $item) {
                Write-Output "Clarisse: nao ha resumo de '$Projeto' na fila"
                break
            }
            Clear-Selecao
            # O texto ja foi historiado no hook Stop; nao duplicar.
            Start-FalaAssincrona (Format-FalaPendente $item) -PularHistorico -ConsomeFila
            Write-Output "Clarisse: lendo o resumo de $($item.projeto) ($($item.restantes) ainda na fila)"
            break
        }

        # Em modo selecao, esta tecla confirma o projeto que estava escolhido.
        $sel = Get-Selecao
        if ($sel) {
            Clear-Selecao
            $item = Read-Pendente -Projeto $sel
            if ($item) {
                Start-FalaAssincrona (Format-FalaPendente $item) -PularHistorico -ConsomeFila
                Write-Output "Clarisse: lendo o resumo de $($item.projeto) ($($item.restantes) ainda na fila)"
                break
            }
        }

        $resumo = @(Get-ResumoDaFila)
        if ($resumo.Count -eq 0) {
            Start-FalaAssincrona 'Nada novo para ler.' -PularHistorico
            Write-Output 'Clarisse: nada pendente'
            break
        }

        $querTriagem = $true
        if ($cfg.PSObject.Properties.Name -contains 'triagem') { $querTriagem = [bool]$cfg.triagem }

        # Com um projeto so na fila, anunciar a lista seria burocracia.
        if ($resumo.Count -eq 1 -or (-not $querTriagem)) {
            $item = Read-Pendente
            if (-not $item) { Write-Output 'Clarisse: nada pendente'; break }
            Start-FalaAssincrona (Format-FalaPendente $item) -PularHistorico -ConsomeFila
            $de = if ($item.projeto) { " de $($item.projeto)" } else { '' }
            Write-Output "Clarisse: lendo o resumo$de ($($item.restantes) ainda na fila)"
            break
        }

        # Varios projetos esperando: anuncia quem sao e entra em modo selecao, em
        # vez de entregar o mais recente e obrigar o usuario a passar por todos os
        # outros - destruindo cada um - para achar o que ele queria.
        $alvo = Start-Selecao
        Start-FalaAssincrona "$(Format-FalaTriagem $resumo) Selecionado: $(Format-FalaProjeto $alvo)." -PularHistorico
        $tPular = if ($cfg.atalhos -and $cfg.atalhos.pular) { $cfg.atalhos.pular } else { 'o atalho de passear' }
        $tLer   = if ($cfg.atalhos -and $cfg.atalhos.ler)   { $cfg.atalhos.ler }   else { 'o atalho de leitura' }
        Write-Output "Clarisse: $($resumo.Count) projetos na fila - selecionado $alvo ($tPular passeia, $tLer le)"
    }

    'proximo' {
        # Passeia pelos projetos da fila sem consumir nem apagar nada.
        $alvo = Move-Selecao
        if (-not $alvo) {
            Start-FalaAssincrona 'Nada novo para ler.' -PularHistorico
            Write-Output 'Clarisse: fila vazia'
            break
        }
        Start-FalaAssincrona (Format-FalaProjeto $alvo) -PularHistorico
        Write-Output "Clarisse: selecionado $alvo"
    }

    'alternar-pausa' {
        if ((Switch-Pausa) -eq 'pausado') { Write-Output 'Clarisse: fala pausada' }
        else                              { Write-Output 'Clarisse: fala retomada' }
    }

    'cancelar' {
        Stop-Fala | Out-Null
        Write-Output 'Clarisse: fala cancelada'
    }

    'atalhos-on' {
        if (Test-AtalhosAtivos) { Write-Output 'Clarisse: atalhos ja estavam ativos'; break }
        if (Start-Atalhos -Aguardar) {
            Write-Output "Clarisse: atalhos ativos - $($cfg.atalhos.ler) le, $($cfg.atalhos.pausar) pausa, $($cfg.atalhos.cancelar) cancela"
        } else {
            Write-Output 'Clarisse: nao consegui registrar os atalhos - outro programa deve estar usando essas teclas. Veja o clarisse.log e troque a combinacao no config.'
        }
    }

    'atalhos-off' {
        if (Stop-Atalhos) { Write-Output 'Clarisse: atalhos desligados' }
        else              { Write-Output 'Clarisse: atalhos ja estavam desligados' }
    }

    'pausar' {
        # Silencia a voz por completo e corta o que estiver tocando.
        $cortou = Stop-Fala
        $cfg.enabled = $false; Save-Config $cfg
        if ($cortou) { Write-Output 'Clarisse: PAUSADA (fala interrompida)' }
        else         { Write-Output 'Clarisse: PAUSADA' }
    }

    'continuar' {
        $cfg.enabled = $true; Save-Config $cfg
        Write-Output 'Clarisse: ATIVA'
    }

    'repetir' {
        $itens = Get-ItensHistorico
        if ($itens.Count -eq 0) { Write-Output 'Clarisse: nada falado ainda'; break }
        if ($Indice -lt 1 -or $Indice -gt $itens.Count) {
            Write-Output "Clarisse: so tenho as ultimas $($itens.Count) falas guardadas"
            break
        }
        $rate = ''
        if ($Devagar) { $rate = Get-RateMaisLento $cfg.rate }
        Invoke-Fala $itens[$Indice - 1] -RateOverride $rate -PularHistorico
        $rotulo = if ($Devagar) { ' (mais devagar)' } else { '' }
        Write-Output "Clarisse: repetiu a fala $Indice de $($itens.Count)$rotulo"
    }

    'historico' {
        $itens = Get-ItensHistorico
        if ($itens.Count -eq 0) { Write-Output 'Clarisse: nada falado ainda'; break }
        for ($i = 0; $i -lt $itens.Count; $i++) {
            $t = $itens[$i]
            if ($t.Length -gt 110) { $t = $t.Substring(0, 110) + '...' }
            Write-Output "$($i + 1). $t"
        }
    }

    'status' {
        $estado = if ($cfg.enabled) { 'ATIVA' } else { 'PAUSADA' }
        $auto = if (($cfg.PSObject.Properties.Name -contains 'autoStart') -and (-not $cfg.autoStart)) { 'nao' } else { 'sim' }
        $qtd = (Get-ItensHistorico).Count
        $qtdFila = Get-PendenteCount
        $fila = if ($qtdFila -eq 0) { 'nenhum' } else { "$qtdFila ($((Get-ProjetosNaFila) -join ', '))" }
        $atalhos = if (Test-AtalhosAtivos) {
            "ATIVOS ($($cfg.atalhos.ler) le / $($cfg.atalhos.pular) passeia / $($cfg.atalhos.pausar) pausa / $($cfg.atalhos.cancelar) cancela)"
        } else { 'DESLIGADOS' }
        $sel = Get-Selecao
        $selTexto = if ($sel) { " | selecionado: $sel" } else { '' }
        Write-Output "Clarisse: $estado | atalhos: $atalhos | resumos na fila: $fila$selTexto | voz: $($cfg.voice) | velocidade: $($cfg.rate) | liga sozinha: $auto | falas guardadas: $qtd"
    }

    'test' {
        Invoke-Fala 'Teste da Clarisse. Voz neural funcionando, velocidade e volume conforme a configuracao atual.' -PularHistorico
        Write-Output 'Teste reproduzido.'
    }

    'say' {
        if ($cfg.enabled) { Invoke-Fala $Text }
    }

    'speak' {
        # Processo filho: le o arquivo pendente, fala e apaga.
        if ($File -and (Test-Path $File)) {
            $conteudo = Get-Content $File -Raw -Encoding utf8
            $semHist = $File -like '*.nohist*'
            $daFila  = $File -like '*.fila*'
            Remove-Item $File -Force -ErrorAction SilentlyContinue
            $estado = if ($semHist) { Invoke-Fala $conteudo -RespeitaEnabled -PularHistorico }
                      else          { Invoke-Fala $conteudo -RespeitaEnabled }
            # O resumo so sai da fila se a fala chegou ao fim. Cortada no meio,
            # ele continua esperando a vez em vez de virar perda silenciosa.
            if ($daFila) {
                if ($estado -eq 'fim') { Complete-Leitura | Out-Null }
                else                   { Abort-Leitura    | Out-Null }
            }
        }
    }

    'stop' {
        # Hook Stop: nao fala. Enfileira o resumo deixado pelo Claude e bipa.
        # O arquivo fala.txt e consumido; quem fala e o modo 'ler'.
        if (-not $cfg.enabled) { exit 0 }
        # Recolhe a caixa de todos os projetos, nao so a desta sessao: a origem
        # vem do nome do arquivo, entao qualquer hook recolhe com atribuicao
        # certa e nenhum resumo fica preso esperando sua sessao terminar.
        $novos = Import-Entradas
        if ($novos.Count -gt 0) {
            foreach ($n in $novos) {
                # Historia aqui para que /clarisse repetir funcione mesmo em
                # resumo que o usuario nunca chegou a mandar ler.
                Add-Historico (ConvertTo-Falavel $n.texto $cfg.maxChars)
            }
            Send-Bipe
        }
    }

    'notify' {
        # Hook Notification: o Claude Code manda um JSON no stdin.
        # Continua falando sozinho: aqui o Claude esta parado esperando voce,
        # e com varias sessoes abertas a fala precisa dizer qual delas.
        if (-not $cfg.enabled) { exit 0 }
        $bruto = Read-StdinDoHook
        $msg = ''
        if ($bruto) {
            try {
                $dados = $bruto | ConvertFrom-Json
                if ($dados.message) { $msg = [string]$dados.message }
            } catch {
                $msg = $bruto
            }
        }
        $falado = Format-FalaNotificacao $msg (Get-NomeProjeto (Get-CwdDoHook $bruto))
        if ($falado) { Start-FalaAssincrona $falado }
    }
}
