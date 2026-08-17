#Requires -Version 5.1
<#
    Nucleo da Clarisse: tudo que clarisse.ps1 e atalhos.ps1 compartilham.
    Carregado por dot-source. Nao executa nada sozinho.

    Para apontar para outra pasta (testes), defina $ClarisseRoot antes do dot-source.
#>

if (-not $ClarisseRoot) { $ClarisseRoot = $PSScriptRoot }

$Root           = $ClarisseRoot
$ConfigPath     = Join-Path $Root 'config.json'
$FalaPath       = Join-Path $Root 'fala.txt'
$PendentePath   = Join-Path $Root 'pendente.txt'
$ControlePath   = Join-Path $Root 'controle.txt'
$HistPath       = Join-Path $Root 'historico.txt'
$PidPath        = Join-Path $Root 'player.pid'
$AtalhosPidPath = Join-Path $Root 'atalhos.pid'
$PendDir        = Join-Path $Root 'pending'
$LogPath        = Join-Path $Root 'clarisse.log'
$Separador      = '---CLARISSE---'
$MaxHist        = 5

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
        maxChars  = 1800
        python    = ''
        atalhos   = [pscustomobject]@{
            ativo    = $true
            ler      = 'Ctrl+Alt+L'
            pausar   = 'Ctrl+Alt+P'
            cancelar = 'Ctrl+Alt+X'
        }
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
    if ([string]::IsNullOrWhiteSpace($texto)) { return }
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

# ------------------------------------------------------- controle do audio

# 'tocar' | 'pausado' | 'cancelar'. O processo que reproduz le isso em laco.
function Get-Controle {
    if (-not (Test-Path $ControlePath)) { return 'tocar' }
    try { $v = ([System.IO.File]::ReadAllText($ControlePath)).Trim().ToLower() } catch { return 'tocar' }
    if (@('tocar', 'pausado', 'cancelar') -contains $v) { return $v }
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

# ------------------------------------------------------- fila de pendencia

function Set-Pendente([string]$texto) {
    [System.IO.File]::WriteAllText($PendentePath, $texto, $Utf8SemBom)
}

function Test-Pendente {
    if (-not (Test-Path $PendentePath)) { return $false }
    try { $t = [System.IO.File]::ReadAllText($PendentePath, [System.Text.Encoding]::UTF8) } catch { return $false }
    return -not [string]::IsNullOrWhiteSpace($t)
}

# Entrega o resumo pendente e o consome: ler duas vezes nao repete a fala.
function Read-Pendente {
    if (-not (Test-Path $PendentePath)) { return '' }
    try { $t = [System.IO.File]::ReadAllText($PendentePath, [System.Text.Encoding]::UTF8) } catch { return '' }
    Remove-Item $PendentePath -Force -ErrorAction SilentlyContinue
    return $t
}

# Aviso curto de "tem resumo esperando". Silencioso se o hardware recusar.
function Send-Bipe {
    try {
        [console]::Beep(880, 120)
        [console]::Beep(1175, 160)
    } catch { }
}

# ------------------------------------------------------- atalhos de teclado

# Traduz "Ctrl+Alt+L" nos codigos que o RegisterHotKey do Win32 espera.
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
    try { $vk = [int]([Enum]::Parse([System.Windows.Forms.Keys], $tecla, $true)) } catch { return $null }
    return @{ mod = ($mod -bor 0x4000); vk = $vk }
}

function Test-AtalhosAtivos {
    if (-not (Test-Path $AtalhosPidPath)) { return $false }
    try { $id = [int](Get-Content $AtalhosPidPath -Raw).Trim() } catch { return $false }
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -like 'powershell*') { return $true }
    Remove-Item $AtalhosPidPath -Force -ErrorAction SilentlyContinue
    return $false
}

# Sobe o escutador. Com -Aguardar, espera ele confirmar que registrou as teclas
# (a compilacao do codigo nativo leva alguns segundos na primeira vez) e devolve
# $false se o Windows recusou as combinacoes.
function Start-Atalhos([switch]$Aguardar) {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'atalhos.ps1')`"" `
        -WindowStyle Hidden | Out-Null
    if (-not $Aguardar) { return $true }
    $limite = [datetime]::Now.AddSeconds(20)
    while ([datetime]::Now -lt $limite) {
        if (Test-AtalhosAtivos) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Stop-Atalhos {
    if (-not (Test-AtalhosAtivos)) { return $false }
    try {
        $id = [int](Get-Content $AtalhosPidPath -Raw).Trim()
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    } catch { }
    Remove-Item $AtalhosPidPath -Force -ErrorAction SilentlyContinue
    return $true
}

# ------------------------------------------------------------- reproducao

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

# Corta a fala em curso. Grava o pedido de cancelamento (o laco de reproducao
# responde em ate 120ms) e, se o edge-tts ainda estiver gerando o audio numa
# chamada bloqueante, mata o processo.
function Stop-Fala {
    Set-Controle 'cancelar'
    Start-Sleep -Milliseconds 350
    $matou = Stop-Reproducao
    Set-Controle 'tocar'
    return $matou
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

        # O PID vai para o disco antes da geracao do audio: cancelar precisa
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

            # A voz pode ter sido desligada enquanto o audio era gerado.
            if ($RespeitaEnabled -and -not (Get-Config).enabled) {
                $player.Close()
                return
            }

            Set-Controle 'tocar'
            $player.Play()
            $pausado = $false
            # Trava de seguranca: uma pausa esquecida nao pode prender o mutex.
            $limite = [datetime]::Now.AddMinutes(20)
            while ($player.Position.TotalSeconds -lt $dur -and [datetime]::Now -lt $limite) {
                switch (Get-Controle) {
                    'cancelar' {
                        $player.Stop(); $player.Close()
                        Set-Controle 'tocar'
                        return
                    }
                    'pausado' { if (-not $pausado) { $player.Pause(); $pausado = $true } }
                    'tocar'   { if ($pausado)      { $player.Play();  $pausado = $false } }
                }
                Start-Sleep -Milliseconds 120
            }
            Start-Sleep -Milliseconds 300
            $player.Stop()
            $player.Close()
            Set-Controle 'tocar'
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
# O sufixo .nohist no nome do arquivo diz ao processo filho para nao historiar
# de novo um texto que ja foi guardado no historico.
function Start-FalaAssincrona([string]$texto, [switch]$PularHistorico) {
    if ([string]::IsNullOrWhiteSpace($texto)) { return }
    if (-not (Test-Path $PendDir)) { New-Item -ItemType Directory -Force $PendDir | Out-Null }
    $sufixo = if ($PularHistorico) { '.nohist' } else { '' }
    $arq = Join-Path $PendDir ("$([guid]::NewGuid().ToString('N'))$sufixo.txt")
    [System.IO.File]::WriteAllText($arq, $texto, $Utf8SemBom)
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'clarisse.ps1')`"", '-Mode', 'speak', '-File', "`"$arq`"" `
        -WindowStyle Hidden | Out-Null
}
