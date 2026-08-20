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
$EntradaDir     = Join-Path $Root 'entrada'
$FilaDir        = Join-Path $Root 'fila'
$PendenteLegado = Join-Path $Root 'pendente.txt'
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

# Quebra o texto nos pedacos que serao sintetizados um a um.
#
# O primeiro segmento e deliberadamente curto: e ele que decide quanto tempo o
# usuario espera em silencio depois de pedir a leitura. Os seguintes podem ser
# maiores, porque a sintese e cerca de tres vezes mais rapida que a fala e ganha
# folga enquanto o primeiro toca. Fragmentar demais tambem custa: cada segmento
# e uma ida ao servidor de voz.
function Split-EmSegmentos {
    param(
        [string]$Texto,
        [int]$PrimeiroMax = 110,
        [int]$DemaisMax   = 320
    )
    if ([string]::IsNullOrWhiteSpace($Texto)) { return ,@() }
    $t = ([regex]::Replace($Texto, '\s+', ' ')).Trim()

    # Fim de frase e pontuacao seguida de espaco. Numero decimal fica inteiro de
    # graca: em "1.500" o ponto nao vem seguido de espaco.
    $frases = @([regex]::Split($t, '(?<=[.!?;])\s+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # Frase maior que o teto e cortada entre palavras, nunca no meio de uma.
    $unidades = New-Object System.Collections.ArrayList
    foreach ($f in $frases) {
        if ($f.Length -le $PrimeiroMax) { [void]$unidades.Add($f); continue }
        $acc = ''
        foreach ($p in ($f -split ' ')) {
            if (-not $acc)                                          { $acc = $p }
            elseif (($acc.Length + 1 + $p.Length) -le $PrimeiroMax) { $acc = "$acc $p" }
            else                                                    { [void]$unidades.Add($acc); $acc = $p }
        }
        if ($acc) { [void]$unidades.Add($acc) }
    }

    $segs = New-Object System.Collections.ArrayList
    $acc = ''
    foreach ($u in $unidades) {
        $limite = if ($segs.Count -eq 0) { $PrimeiroMax } else { $DemaisMax }
        if (-not $acc)                                      { $acc = $u }
        elseif (($acc.Length + 1 + $u.Length) -le $limite)  { $acc = "$acc $u" }
        else                                                { [void]$segs.Add($acc); $acc = $u }
    }
    if ($acc) { [void]$segs.Add($acc) }

    # A virgula impede o PowerShell de desembrulhar array de um elemento so.
    return ,$segs.ToArray()
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
#
# Uma pasta com um arquivo por resumo, nome ordenavel pelo instante de criacao.
# Tem que ser uma fila, e nao um arquivo unico: todas as sessoes do Claude Code
# compartilham esta pasta, e com arquivo unico a sessao que termina depois apaga
# o resumo da que terminou antes - o usuario nunca ouve o primeiro.

$MaxFila = 20

function Get-ArquivosFila {
    Import-PendenteLegado
    if (-not (Test-Path $FilaDir)) { return @() }
    return @(Get-ChildItem -Path $FilaDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

# Aproveita o pendente.txt de uma instalacao anterior em vez de descarta-lo.
function Import-PendenteLegado {
    if (-not (Test-Path $PendenteLegado)) { return }
    try {
        $t = [System.IO.File]::ReadAllText($PendenteLegado, [System.Text.Encoding]::UTF8)
        Remove-Item $PendenteLegado -Force -ErrorAction SilentlyContinue
        Add-Pendente $t ''
    } catch { }
}

function Add-Pendente([string]$texto, [string]$projeto) {
    if ([string]::IsNullOrWhiteSpace($texto)) { return }
    if (-not (Test-Path $FilaDir)) { New-Item -ItemType Directory -Force $FilaDir | Out-Null }

    # Duas sessoes podem terminar no mesmo milissegundo, e o relogio do Windows
    # tem granularidade grossa demais para separa-las - Import-Entradas ainda
    # enfileira todas as caixas em laco, no mesmo processo. Medido: 34% dos
    # pares caem no mesmo milissegundo. Com o guid aleatorio como unico
    # desempate, a fila saia invertida em 22% das vezes; o contador preserva a
    # ordem de chegada e o guid fica so para evitar colisao entre processos.
    $ms = (Get-Date).ToString('yyyyMMddHHmmssfff')
    $seq = @(Get-ChildItem -Path $FilaDir -Filter "$ms-*.json" -File -ErrorAction SilentlyContinue).Count
    $nome = "$ms-$('{0:d3}' -f $seq)-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    $dados = [pscustomobject]@{ projeto = $projeto; texto = $texto }
    [System.IO.File]::WriteAllText((Join-Path $FilaDir $nome), ($dados | ConvertTo-Json -Depth 3), $Utf8SemBom)

    $arquivos = @(Get-ChildItem -Path $FilaDir -Filter '*.json' -File | Sort-Object Name)
    if ($arquivos.Count -gt $MaxFila) {
        $arquivos[0..($arquivos.Count - $MaxFila - 1)] | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Get-PendenteCount {
    return (Get-ArquivosFila).Count
}

function Test-Pendente {
    return (Get-ArquivosFila).Count -gt 0
}

# Entrega o resumo mais recente e o consome. O mais novo primeiro porque e o
# que acabou de bipar; os antigos continuam na fila esperando a vez.
function Read-Pendente {
    $arquivos = Get-ArquivosFila
    if ($arquivos.Count -eq 0) { return $null }
    $alvo = $arquivos[-1]
    try {
        $dados = [System.IO.File]::ReadAllText($alvo.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        Remove-Item $alvo.FullName -Force -ErrorAction SilentlyContinue
        return $null
    }
    Remove-Item $alvo.FullName -Force -ErrorAction SilentlyContinue
    return @{
        texto     = [string]$dados.texto
        projeto   = [string]$dados.projeto
        restantes = $arquivos.Count - 1
    }
}

# ------------------------------------------------- caixa de entrada por projeto
#
# O Claude escreve o resumo aqui, num arquivo com o nome do projeto. Nao pode
# ser um arquivo unico: as sessoes compartilham esta pasta e a que escreve por
# ultimo apagaria o resumo da anterior antes de qualquer hook ler.
#
# O nome do arquivo e a fonte da verdade sobre a origem. Por isso o hook recolhe
# TODAS as caixas, e nao so a do proprio projeto: qualquer sessao que termine
# recolhe o que estiver parado, sempre com a atribuicao certa, e nada fica preso
# esperando aquela sessao especifica terminar de novo.

function Get-CaminhoEntrada([string]$projeto) {
    if ([string]::IsNullOrWhiteSpace($projeto)) { return '' }
    $limpo = $projeto
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $limpo = $limpo.Replace($c, '-') }
    return (Join-Path $EntradaDir "$limpo.txt")
}

# Move tudo que esta na caixa de entrada para a fila de leitura.
# Devolve o que enfileirou, para o chamador historiar e decidir se bipa.
function Import-Entradas {
    $novos = New-Object System.Collections.ArrayList

    if (Test-Path $EntradaDir) {
        $caixas = @(Get-ChildItem -Path $EntradaDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
        foreach ($caixa in $caixas) {
            try { $texto = [System.IO.File]::ReadAllText($caixa.FullName, [System.Text.Encoding]::UTF8) } catch { continue }
            Remove-Item $caixa.FullName -Force -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($texto)) { continue }
            Add-Pendente $texto $caixa.BaseName
            [void]$novos.Add(@{ projeto = $caixa.BaseName; texto = $texto })
        }
    }

    # fala.txt de uma instalacao anterior: entra sem projeto, porque nao da para
    # saber de qual sessao veio - e etiqueta errada e pior que etiqueta nenhuma.
    if (Test-Path $FalaPath) {
        try { $texto = [System.IO.File]::ReadAllText($FalaPath, [System.Text.Encoding]::UTF8) } catch { $texto = '' }
        Remove-Item $FalaPath -Force -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($texto)) {
            Add-Pendente $texto ''
            [void]$novos.Add(@{ projeto = ''; texto = $texto })
        }
    }

    # A virgula impede o PowerShell de desembrulhar array de um elemento so,
    # o que faria .Count devolver o numero de chaves do hashtable.
    return ,$novos.ToArray()
}

# Quem esta esperando, do mais recente para o mais antigo, sem repetir projeto.
function Get-ProjetosNaFila {
    $nomes = New-Object System.Collections.ArrayList
    $arquivos = Get-ArquivosFila
    for ($i = $arquivos.Count - 1; $i -ge 0; $i--) {
        try { $dados = [System.IO.File]::ReadAllText($arquivos[$i].FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        $nome = if ($dados.projeto) { [string]$dados.projeto } else { 'sem nome' }
        if (-not $nomes.Contains($nome)) { [void]$nomes.Add($nome) }
    }
    return ,$nomes.ToArray()
}

$NumeroPorExtenso = @{
    1 = 'um'; 2 = 'dois'; 3 = 'tres'; 4 = 'quatro'; 5 = 'cinco';
    6 = 'seis'; 7 = 'sete'; 8 = 'oito'; 9 = 'nove'; 10 = 'dez'
}

# Monta o que sai pela voz: de onde veio, o resumo, e quantos ainda esperam.
function Format-FalaPendente($item) {
    $t = $item.texto
    if ($item.projeto) { $t = "No projeto $($item.projeto): $t" }
    $n = [int]$item.restantes
    if ($n -eq 1) {
        $t = "$t Tem mais um resumo esperando."
    } elseif ($n -gt 1) {
        $q = if ($NumeroPorExtenso.ContainsKey($n)) { $NumeroPorExtenso[$n] } else { "$n" }
        $t = "$t Tem mais $q resumos esperando."
    }
    return $t
}

# Com varias sessoes abertas, "estou esperando sua resposta" nao diz nada:
# o usuario precisa saber para qual terminal ir.
function Format-FalaNotificacao([string]$msg, [string]$projeto) {
    if ([string]::IsNullOrWhiteSpace($msg)) { return '' }
    $traducoes = @(
        @{ chave = 'needs your permission';  comProjeto = 'precisa da sua permissao para continuar.'; sozinho = 'Preciso da sua permissao para continuar.' },
        @{ chave = 'waiting for your input'; comProjeto = 'esta esperando sua resposta.';             sozinho = 'Estou esperando sua resposta.' },
        @{ chave = 'is waiting';             comProjeto = 'esta esperando sua resposta.';             sozinho = 'Estou esperando sua resposta.' }
    )
    foreach ($t in $traducoes) {
        if ($msg -like "*$($t.chave)*") {
            if ($projeto) { return "O projeto $projeto $($t.comProjeto)" }
            return $t.sozinho
        }
    }
    if ($projeto) { return "No projeto ${projeto}: $msg" }
    return $msg
}

function Get-NomeProjeto([string]$cwd) {
    if ([string]::IsNullOrWhiteSpace($cwd)) { return '' }
    try { return Split-Path -Leaf $cwd.TrimEnd('\', '/') } catch { return '' }
}

# O Claude Code manda um JSON no stdin dos hooks, com o diretorio da sessao.
function Get-CwdDoHook([string]$bruto) {
    if ([string]::IsNullOrWhiteSpace($bruto)) { return '' }
    try {
        $dados = $bruto | ConvertFrom-Json
        if ($dados.cwd) { return [string]$dados.cwd }
    } catch { }
    return ''
}

# Le o stdin sem travar quando o script e chamado a mao num terminal.
function Read-StdinDoHook {
    try {
        if (-not [Console]::IsInputRedirected) { return '' }
        return [Console]::In.ReadToEnd()
    } catch { return '' }
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

# ------------------------------------------------- sintese progressiva
#
# O texto vai para um script Python que sintetiza segmento por segmento, e a
# reproducao acontece aqui, na ordem em que cada pedaco fica pronto. Assim a
# fala comeca em cerca de dois segundos em vez de esperar o audio inteiro:
# sintetizar e cerca de tres vezes mais rapido que falar, entao depois do
# primeiro segmento a geracao sempre corre na frente da voz.
#
# O sinal de "pode tocar" e a sentinela .ok, escrita somente depois de o mp3
# ser fechado. A existencia do mp3 nao serve: um arquivo ainda em gravacao abre
# no player com duracao errada e a fala corta no meio.

function Get-CaminhoSegmento([string]$pasta, [int]$indice) {
    return (Join-Path $pasta ('seg{0:d3}.mp3' -f $indice))
}

function Get-CaminhoSentinela([string]$pasta, [int]$indice) {
    return (Join-Path $pasta ('seg{0:d3}.ok' -f $indice))
}

function Test-SegmentoPronto([string]$pasta, [int]$indice) {
    if (-not (Test-Path (Get-CaminhoSentinela $pasta $indice))) { return $false }
    return [bool](Test-Path (Get-CaminhoSegmento $pasta $indice))
}

# Espera o proximo pedaco de audio. Devolve 'pronto', 'erro', 'timeout' ou
# 'cancelado'. A ordem das checagens importa: um segmento que ja esta pronto
# vale mesmo que o Python tenha falhado num segmento posterior.
function Wait-SegmentoPronto([string]$pasta, [int]$indice, [int]$timeoutSegundos) {
    $limite = [datetime]::Now.AddSeconds($timeoutSegundos)
    while ($true) {
        if (Test-SegmentoPronto $pasta $indice)      { return 'pronto' }
        if ((Get-Controle) -eq 'cancelar')           { return 'cancelado' }
        if (Test-Path (Join-Path $pasta 'erro.txt')) { return 'erro' }
        if ([datetime]::Now -ge $limite)             { return 'timeout' }
        Start-Sleep -Milliseconds 60
    }
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
