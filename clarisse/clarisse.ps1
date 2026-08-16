#Requires -Version 5.1
<#
    Clarisse - voz para o Claude Code no Windows.
    Gera fala neural (edge-tts) e reproduz sem depender de player externo.

    Modos:
      say       -Text "..."   fala o texto informado
      speak     -File "..."   fala o conteudo de um arquivo (uso interno, background)
      stop                    hook Stop: fala o resumo deixado em fala.txt
      notify                  hook Notification: fala a mensagem recebida no stdin
      autostart               hook SessionStart: religa a voz ao abrir o Claude Code
      on / off / toggle       liga, desliga ou alterna a voz
      pausar                  corta o audio em curso e silencia
      continuar               volta a falar
      repetir   -Indice N     repete a N-esima fala mais recente (1 = ultima)
                -Devagar      repete mais lentamente
      historico               lista as ultimas falas
      status                  mostra o estado atual
      test                    fala uma frase de teste
#>
param(
    [ValidateSet('say', 'speak', 'stop', 'notify', 'autostart', 'on', 'off', 'toggle',
                 'pausar', 'continuar', 'repetir', 'historico', 'status', 'test')]
    [string]$Mode = 'say',
    [string]$Text = '',
    [string]$File = '',
    [int]$Indice = 1,
    [switch]$Devagar
)

$ErrorActionPreference = 'Stop'
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$FalaPath   = Join-Path $Root 'fala.txt'
$HistPath   = Join-Path $Root 'historico.txt'
$PidPath    = Join-Path $Root 'player.pid'
$PendDir    = Join-Path $Root 'pending'
$LogPath    = Join-Path $Root 'clarisse.log'
$Separador  = '---CLARISSE---'
$MaxHist    = 5

$Utf8SemBom = New-Object System.Text.UTF8Encoding($false)

function Write-Log($msg) {
    try {
        $stamp = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss')
        Add-Content -Path $LogPath -Value "[$stamp] $msg" -Encoding utf8
    } catch { }
}

function Get-Config {
    if (Test-Path $ConfigPath) {
        try { return Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{
        enabled   = $true
        autoStart = $true
        voice     = 'pt-BR-ThalitaMultilingualNeural'
        rate      = '+12%'
        volume    = '+0%'
        maxChars  = 700
        python    = ''
    }
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Out-File -FilePath $ConfigPath -Encoding utf8
}

# Descobre como invocar o Python. O campo "python" do config tem prioridade;
# sem ele, procura instalacoes comuns e cai no launcher "py -3" como ultimo recurso.
function Get-PythonInvocacao($cfg) {
    if ($cfg.python -and (Test-Path $cfg.python)) {
        return @{ exe = $cfg.python; pre = @() }
    }
    $candidatos = @(
        "$env:LOCALAPPDATA\Python\bin\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) { return @{ exe = $c; pre = @() } }
    }
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    # O stub da Microsoft Store abre a loja em vez de rodar Python.
    if ($cmd -and $cmd.Source -and $cmd.Source -notlike '*WindowsApps*') {
        return @{ exe = $cmd.Source; pre = @() }
    }
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        return @{ exe = 'py'; pre = @('-3') }
    }
    return $null
}

# Remove marcacao que nao faz sentido em audio e limita o tamanho da fala.
function ConvertTo-Falavel([string]$raw, [int]$maxChars) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $t = $raw
    $t = [regex]::Replace($t, '(?s)```.*?```', ' ')
    $t = [regex]::Replace($t, '`([^`]*)`', '$1')
    $t = [regex]::Replace($t, '!?\[([^\]]*)\]\([^)]*\)', '$1')
    $t = [regex]::Replace($t, '^\s{0,3}#{1,6}\s*', '', 'Multiline')
    $t = [regex]::Replace($t, '\*\*([^*]*)\*\*', '$1')
    $t = [regex]::Replace($t, '(?<!\w)\*([^*]+)\*(?!\w)', '$1')
    $t = [regex]::Replace($t, '^\s*[-*+]\s+', '', 'Multiline')
    $t = [regex]::Replace($t, '\|', ' ')
    $t = [regex]::Replace($t, '\s+', ' ')
    $t = $t.Trim()
    if ($t.Length -gt $maxChars) {
        $corte = $t.Substring(0, $maxChars)
        $ultimo = $corte.LastIndexOfAny([char[]]@('.', '!', '?', ';'))
        if ($ultimo -gt ($maxChars * 0.5)) { $corte = $corte.Substring(0, $ultimo + 1) }
        $t = $corte.TrimEnd() + '...'
    }
    return $t
}

function Get-ItensHistorico {
    if (-not (Test-Path $HistPath)) { return @() }
    try {
        $bruto = [System.IO.File]::ReadAllText($HistPath, [System.Text.Encoding]::UTF8)
    } catch { return @() }
    return @($bruto -split [regex]::Escape($Separador) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Add-Historico([string]$texto) {
    $itens = @($texto) + (Get-ItensHistorico)
    if ($itens.Count -gt $MaxHist) { $itens = $itens[0..($MaxHist - 1)] }
    [System.IO.File]::WriteAllText($HistPath, ($itens -join "`n$Separador`n"), $Utf8SemBom)
}

# Converte "+12%" para "-13%" quando o usuario pede repeticao mais lenta.
function Get-RateMaisLento([string]$rate) {
    $n = 0
    if ($rate -match '^([+-]?\d+)%$') { $n = [int]$Matches[1] }
    $n = $n - 25
    if ($n -lt -40) { $n = -40 }
    if ($n -ge 0) { return "+$n%" }
    return "$n%"
}

function Stop-Reproducao {
    if (-not (Test-Path $PidPath)) { return $false }
    $parou = $false
    try {
        $id = [int](Get-Content $PidPath -Raw).Trim()
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -like 'powershell*' -and $id -ne $PID) {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            $parou = $true
        }
    } catch { }
    Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
    return $parou
}

# Gera o audio e toca. Bloqueia ate terminar; um mutex evita falas sobrepostas.
function Invoke-Fala {
    param(
        [string]$texto,
        [string]$RateOverride = '',
        [switch]$PularHistorico,
        [switch]$RespeitaEnabled
    )
    $cfg = Get-Config
    $falavel = ConvertTo-Falavel $texto $cfg.maxChars
    if ([string]::IsNullOrWhiteSpace($falavel)) { return }

    $inv = Get-PythonInvocacao $cfg
    if (-not $inv) {
        Write-Log 'Python nao encontrado. Defina o caminho no campo "python" do config.json.'
        return
    }

    $rate = if ($RateOverride) { $RateOverride } else { $cfg.rate }

    $mutex = New-Object System.Threading.Mutex($false, 'Global\ClarisseVoz')
    $obteve = $false
    try {
        $obteve = $mutex.WaitOne(60000)
        if (-not $PularHistorico) { Add-Historico $falavel }

        # O PID vai para o disco antes da geracao do audio: 'pausar' precisa
        # interromper tambem enquanto o edge-tts ainda esta baixando a fala.
        [System.IO.File]::WriteAllText($PidPath, "$PID", $Utf8SemBom)

        $id  = [guid]::NewGuid().ToString('N')
        $txt = Join-Path $env:TEMP "clarisse_$id.txt"
        $mp3 = Join-Path $env:TEMP "clarisse_$id.mp3"
        try {
            [System.IO.File]::WriteAllText($txt, $falavel, $Utf8SemBom)

            $argumentos = $inv.pre + @(
                '-m', 'edge_tts',
                '--voice', $cfg.voice,
                '--rate', $rate,
                '--volume', $cfg.volume,
                '--file', $txt,
                '--write-media', $mp3
            )
            & $inv.exe @argumentos 2>$null | Out-Null

            if (-not (Test-Path $mp3)) { Write-Log 'falha ao gerar mp3'; return }
            if ((Get-Item $mp3).Length -lt 200) { Write-Log 'mp3 vazio'; return }

            Add-Type -AssemblyName PresentationCore
            $player = New-Object System.Windows.Media.MediaPlayer
            $player.Open([uri]$mp3)
            $espera = 0
            while (-not $player.NaturalDuration.HasTimeSpan -and $espera -lt 100) {
                Start-Sleep -Milliseconds 50
                $espera++
            }
            if (-not $player.NaturalDuration.HasTimeSpan) { Write-Log 'mp3 ilegivel'; return }
            $dur = $player.NaturalDuration.TimeSpan.TotalSeconds

            # A voz pode ter sido pausada enquanto o audio era gerado.
            if ($RespeitaEnabled -and -not (Get-Config).enabled) {
                $player.Close()
                return
            }
            $player.Play()
            Start-Sleep -Milliseconds ([int](($dur * 1000) + 400))
            $player.Stop()
            $player.Close()
        } finally {
            Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
            Remove-Item $txt -Force -ErrorAction SilentlyContinue
            Remove-Item $mp3 -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($obteve) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Dispara a fala num processo separado para nao travar o Claude Code.
function Start-FalaAssincrona([string]$texto) {
    if ([string]::IsNullOrWhiteSpace($texto)) { return }
    if (-not (Test-Path $PendDir)) { New-Item -ItemType Directory -Force $PendDir | Out-Null }
    $arq = Join-Path $PendDir ("$([guid]::NewGuid().ToString('N')).txt")
    [System.IO.File]::WriteAllText($arq, $texto, $Utf8SemBom)
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) { $self = Join-Path $Root 'clarisse.ps1' }
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"", '-Mode', 'speak', '-File', "`"$arq`"" `
        -WindowStyle Hidden | Out-Null
}

$cfg = Get-Config

switch ($Mode) {

    'autostart' {
        # Hook SessionStart: garante que a voz volta ligada a cada sessao nova.
        if ($cfg.PSObject.Properties.Name -notcontains 'autoStart') {
            $cfg | Add-Member -NotePropertyName autoStart -NotePropertyValue $true -Force
        }
        if ($cfg.autoStart -and -not $cfg.enabled) {
            $cfg.enabled = $true
            Save-Config $cfg
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

    'pausar' {
        # Corta o audio em curso na hora e silencia ate mandar continuar.
        $cortou = Stop-Reproducao
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
        Write-Output "Clarisse: $estado | voz: $($cfg.voice) | velocidade: $($cfg.rate) | liga sozinha: $auto | falas guardadas: $qtd"
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
            Remove-Item $File -Force -ErrorAction SilentlyContinue
            Invoke-Fala $conteudo -RespeitaEnabled
        }
    }

    'stop' {
        # Hook Stop: so fala se houver um resumo deixado pelo Claude. O arquivo e consumido.
        if (-not $cfg.enabled) { exit 0 }
        if (Test-Path $FalaPath) {
            $resumo = Get-Content $FalaPath -Raw -Encoding utf8
            Remove-Item $FalaPath -Force -ErrorAction SilentlyContinue
            Start-FalaAssincrona $resumo
        }
    }

    'notify' {
        # Hook Notification: o Claude Code manda um JSON no stdin.
        if (-not $cfg.enabled) { exit 0 }
        $bruto = [Console]::In.ReadToEnd()
        $msg = ''
        if ($bruto) {
            try {
                $dados = $bruto | ConvertFrom-Json
                if ($dados.message) { $msg = [string]$dados.message }
            } catch {
                $msg = $bruto
            }
        }
        if ($msg) {
            $traducoes = @{
                'needs your permission'  = 'Preciso da sua permissao para continuar.'
                'waiting for your input' = 'Estou esperando sua resposta.'
                'is waiting'             = 'Estou esperando sua resposta.'
            }
            $falado = $null
            foreach ($chave in $traducoes.Keys) {
                if ($msg -like "*$chave*") { $falado = $traducoes[$chave]; break }
            }
            if (-not $falado) { $falado = $msg }
            Start-FalaAssincrona $falado
        }
    }
}
