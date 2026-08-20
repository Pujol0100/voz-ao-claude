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
$EmLeituraPath  = Join-Path $Root 'emleitura.txt'
$SelecaoPath    = Join-Path $Root 'selecao.txt'
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
        triagem   = $true
        atalhos   = [pscustomobject]@{
            ativo    = $true
            ler      = 'Ctrl+Alt+L'
            pular    = 'Ctrl+Alt+J'
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
    if ([string]::IsNullOrWhiteSpace($Texto)) { return @() }
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

    # Sem o operador virgula aqui de proposito: quem chama envolve em @(), e os
    # dois juntos criariam um array dentro de um array - o texto inteiro voltaria
    # a ser um unico segmento e a espera voltaria com ele.
    return $segs.ToArray()
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

# Le o conteudo de um arquivo da fila. Devolve $null se veio corrompido.
function Read-DadosFila($arquivo) {
    try {
        return [System.IO.File]::ReadAllText($arquivo.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        return $null
    }
}

# Entrega um resumo para leitura, sem apaga-lo. Com -Projeto, entrega o mais
# recente daquele projeto em vez do mais recente da fila.
#
# O resumo so sai do disco quando a fala termina de verdade (Complete-Leitura).
# Antes, o arquivo era apagado no momento da entrega: quem cancelasse ao ouvir
# "no projeto tal" e perceber que era o projeto errado perdia aquele resumo para
# sempre. Cacar o resumo certo destruia todos os que passavam na frente.
function Read-Pendente {
    param([string]$Projeto = '')

    # Uma leitura anterior que nao terminou devolve o resumo para a fila: se o
    # processo que falava foi morto, ninguem chamou Complete nem Abort. Assim o
    # pior caso e ouvir o mesmo resumo de novo, nunca perde-lo.
    Abort-Leitura | Out-Null

    $arquivos = Get-ArquivosFila
    if ($arquivos.Count -eq 0) { return $null }

    $alvo  = $null
    $dados = $null

    if ($Projeto) {
        $busca = $Projeto.ToLower()
        for ($i = $arquivos.Count - 1; $i -ge 0; $i--) {
            $d = Read-DadosFila $arquivos[$i]
            if (-not $d) { continue }
            $nome = [string]$d.projeto
            # Nome parcial serve: digitar "concil" tem de achar a conciliacao.
            if ($nome -and $nome.ToLower().Contains($busca)) {
                $alvo = $arquivos[$i]; $dados = $d; break
            }
        }
        if (-not $alvo) { return $null }
    } else {
        $alvo  = $arquivos[-1]
        $dados = Read-DadosFila $alvo
        if (-not $dados) {
            Remove-Item $alvo.FullName -Force -ErrorAction SilentlyContinue
            return $null
        }
    }

    [System.IO.File]::WriteAllText($EmLeituraPath, $alvo.Name, $Utf8SemBom)
    return @{
        texto     = [string]$dados.texto
        projeto   = [string]$dados.projeto
        restantes = $arquivos.Count - 1
    }
}

# A fala chegou ao fim: agora o resumo pode sair da fila.
function Complete-Leitura {
    if (-not (Test-Path $EmLeituraPath)) { return $false }
    try { $nome = ([System.IO.File]::ReadAllText($EmLeituraPath)).Trim() } catch { $nome = '' }
    Remove-Item $EmLeituraPath -Force -ErrorAction SilentlyContinue
    if (-not $nome) { return $false }
    $alvo = Join-Path $FilaDir $nome
    if (Test-Path $alvo) {
        Remove-Item $alvo -Force -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

# A fala foi cortada: o resumo continua na fila esperando a vez.
function Abort-Leitura {
    if (-not (Test-Path $EmLeituraPath)) { return $false }
    Remove-Item $EmLeituraPath -Force -ErrorAction SilentlyContinue
    return $true
}

# Quem esta esperando e quantos resumos cada um deixou, do mais recente para o
# mais antigo. E o que a triagem falada anuncia.
function Get-ResumoDaFila {
    $ordem  = New-Object System.Collections.ArrayList
    $contas = @{}
    $arquivos = Get-ArquivosFila
    for ($i = $arquivos.Count - 1; $i -ge 0; $i--) {
        $d = Read-DadosFila $arquivos[$i]
        if (-not $d) { continue }
        $nome = if ($d.projeto) { [string]$d.projeto } else { 'sem nome' }
        if (-not $contas.ContainsKey($nome)) {
            $contas[$nome] = 0
            [void]$ordem.Add($nome)
        }
        $contas[$nome] = $contas[$nome] + 1
    }
    $saida = New-Object System.Collections.ArrayList
    foreach ($n in $ordem) { [void]$saida.Add(@{ projeto = $n; quantos = $contas[$n] }) }
    return $saida.ToArray()
}

# Traduz um numero pequeno para palavra, para a voz nao soletrar digito.
function Get-PorExtenso([int]$n) {
    if ($NumeroPorExtenso.ContainsKey($n)) { return $NumeroPorExtenso[$n] }
    return "$n"
}

# Quantos nomes a triagem cita antes de resumir o resto. Medido com a fila real:
# listar seis projetos com a contagem de cada um dava 334 caracteres, uns 25
# segundos so para anunciar a lista - ouvir isso a cada leitura seria pior que o
# problema que a triagem resolve.
$MaxNomesTriagem = 5

# A frase que a Clarisse fala antes de ler, quando ha mais de um projeto na fila.
# Diz os totais e os nomes, nao a contagem de cada projeto: o que o usuario
# precisa para escolher e saber quem esta esperando, e o resto ele ouve depois.
# O hifen sai porque nome de pasta soletrado em voz alta e ilegivel.
function Format-FalaTriagem($itens) {
    $lista = @($itens)
    if ($lista.Count -eq 0) { return '' }

    $n = $lista.Count
    $total = 0
    foreach ($i in $lista) { $total += [int]$i.quantos }

    $citados = @($lista | Select-Object -First $MaxNomesTriagem |
                 ForEach-Object { ([string]$_.projeto).Replace('-', ' ') })
    $sobram = $n - $citados.Count

    if ($citados.Count -eq 1) {
        $nomes = $citados[0]
    } else {
        # "alfa, beta e gama" soa melhor que "alfa, beta, gama".
        $nomes = ($citados[0..($citados.Count - 2)] -join ', ') + " e $($citados[-1])"
    }
    if ($sobram -gt 0) {
        # "e mais um" solto soa como mais um resumo; o que sobra e projeto.
        $pSobra = if ($sobram -eq 1) { 'projeto' } else { 'projetos' }
        $nomes = ($citados -join ', ') + ", e mais $(Get-PorExtenso $sobram) $pSobra"
    }

    $pProj = if ($n -eq 1)     { 'projeto' } else { 'projetos' }
    $pRes  = if ($total -eq 1) { 'resumo' }  else { 'resumos' }
    return "$(Get-PorExtenso $n) $pProj esperando, $(Get-PorExtenso $total) ${pRes}: $nomes."
}

# O nome do projeto como a voz deve dizer: hifen soletrado em voz alta e
# ilegivel, e "velocimetro-tokens" sai como "velocimetro traco tokens".
function Format-FalaProjeto([string]$projeto) {
    if ([string]::IsNullOrWhiteSpace($projeto)) { return '' }
    return $projeto.Replace('-', ' ')
}

# ------------------------------------------------------- modo selecao
#
# Com varios projetos na fila, o atalho de leitura anuncia quem esta esperando e
# entra em modo selecao: uma tecla passeia pelos projetos e a de leitura confirma.
# Passear nao consome nem apaga nada.

function Get-Selecao {
    if (-not (Test-Path $SelecaoPath)) { return '' }
    try { $nome = ([System.IO.File]::ReadAllText($SelecaoPath)).Trim() } catch { return '' }
    if (-not $nome) { return '' }
    # Sem virgula em @() aqui: Get-ProjetosNaFila ja devolve o array protegido,
    # e envolver de novo criaria array dentro de array.
    $projetos = Get-ProjetosNaFila
    if ($projetos -notcontains $nome) {
        # A selecao expira junto com o motivo dela existir.
        Clear-Selecao
        return ''
    }
    return $nome
}

function Set-Selecao([string]$projeto) {
    [System.IO.File]::WriteAllText($SelecaoPath, $projeto, $Utf8SemBom)
}

function Clear-Selecao {
    Remove-Item $SelecaoPath -Force -ErrorAction SilentlyContinue
}

function Start-Selecao {
    $projetos = Get-ProjetosNaFila
    if ($projetos.Count -eq 0) { Clear-Selecao; return '' }
    Set-Selecao $projetos[0]
    return $projetos[0]
}

# Passa para o proximo projeto, dando a volta no fim da lista.
function Move-Selecao {
    $projetos = Get-ProjetosNaFila
    if ($projetos.Count -eq 0) { Clear-Selecao; return '' }
    $atual = Get-Selecao
    $i = [array]::IndexOf([array]$projetos, $atual)
    $prox = if ($i -lt 0) { 0 } else { ($i + 1) % $projetos.Count }
    Set-Selecao $projetos[$prox]
    return $projetos[$prox]
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

# Vai ate vinte porque vinte e o teto da fila. Digito solto na fala sai lido de
# formas imprevisiveis, entao todo numero que o sistema pode produzir tem de ter
# palavra aqui.
$NumeroPorExtenso = @{
    1 = 'um';    2 = 'dois';    3 = 'tres';    4 = 'quatro';   5 = 'cinco'
    6 = 'seis';  7 = 'sete';    8 = 'oito';    9 = 'nove';    10 = 'dez'
    11 = 'onze'; 12 = 'doze';  13 = 'treze';  14 = 'quatorze'; 15 = 'quinze'
    16 = 'dezesseis'; 17 = 'dezessete'; 18 = 'dezoito'; 19 = 'dezenove'; 20 = 'vinte'
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

# Toca um pedaco de audio ate o fim, obedecendo pausa e cancelamento.
# Devolve 'fim', 'cancelado' ou 'ilegivel' - o laco de reproducao trata os tres
# de formas diferentes, e um booleano nao daria para distinguir.
function Invoke-TocaArquivo([string]$mp3) {
    # Antes de abrir o arquivo, para o Ctrl+Alt+X responder na hora em vez de
    # esperar o pedaco atual carregar.
    if ((Get-Controle) -eq 'cancelar') { return 'cancelado' }
    if (-not (Test-Path $mp3))         { return 'ilegivel' }

    Add-Type -AssemblyName PresentationCore
    $player = New-Object System.Windows.Media.MediaPlayer
    try {
        $player.Open([uri]$mp3)
        # O MediaPlayer carrega o arquivo de forma assincrona e nao lanca erro
        # em arquivo invalido: a duracao nunca aparecer e o sinal de que veio
        # corrompido.
        $espera = 0
        while (-not $player.NaturalDuration.HasTimeSpan -and $espera -lt 60) {
            Start-Sleep -Milliseconds 50
            $espera++
        }
        if (-not $player.NaturalDuration.HasTimeSpan) { return 'ilegivel' }
        $dur = $player.NaturalDuration.TimeSpan.TotalSeconds

        $player.Play()
        $pausado = $false
        # Trava de seguranca: uma pausa esquecida nao pode prender o mutex.
        $limite = [datetime]::Now.AddMinutes(20)
        while ($player.Position.TotalSeconds -lt $dur -and [datetime]::Now -lt $limite) {
            switch (Get-Controle) {
                'cancelar' { return 'cancelado' }
                'pausado'  { if (-not $pausado) { $player.Pause(); $pausado = $true } }
                'tocar'    { if ($pausado)      { $player.Play();  $pausado = $false } }
            }
            Start-Sleep -Milliseconds 120
        }
        # Evita cortar a ultima silaba; entre segmentos soa como pausa de frase.
        Start-Sleep -Milliseconds 120
        return 'fim'
    } finally {
        $player.Stop()
        $player.Close()
    }
}

# Gera o audio e toca. Bloqueia ate terminar; um mutex evita falas sobrepostas.
#
# A sintese acontece em pedacos, num processo Python a parte, e a reproducao
# comeca no primeiro pedaco em vez de esperar o audio inteiro. Medido num resumo
# de mil e quinhentos caracteres: 33 segundos de espera antes, cerca de dois
# depois. Sintetizar e umas tres vezes mais rapido que falar, entao a geracao
# corre na frente da voz e nao engasga entre os pedacos.
function Invoke-Fala {
    param(
        [string]$texto,
        [string]$RateOverride = '',
        [switch]$PularHistorico,
        [switch]$RespeitaEnabled
    )
    $cfg = Get-Config
    $falavel = ConvertTo-Falavel $texto $cfg.maxChars
    if ([string]::IsNullOrWhiteSpace($falavel)) { return 'vazio' }

    $inv = Get-PythonInvocacao $cfg
    if (-not $inv) {
        Write-Log 'Python nao encontrado. Defina o caminho no campo "python" do config.json.'
        return 'erro'
    }

    $rate = if ($RateOverride) { $RateOverride } else { $cfg.rate }

    $mutex = New-Object System.Threading.Mutex($false, 'Global\ClarisseVoz')
    $obteve = $false
    try {
        $obteve = $mutex.WaitOne(60000)
        if (-not $PularHistorico) { Add-Historico $falavel }

        # O PID vai para o disco antes da sintese: cancelar precisa interromper
        # tambem enquanto o audio ainda esta sendo gerado.
        [System.IO.File]::WriteAllText($PidPath, "$PID", $Utf8SemBom)

        $segmentos = @(Split-EmSegmentos -Texto $falavel)
        if ($segmentos.Count -eq 0) { return 'vazio' }

        $pasta = Join-Path $env:TEMP "clarisse_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force $pasta | Out-Null
        $proc = $null
        try {
            [System.IO.File]::WriteAllLines((Join-Path $pasta 'segmentos.txt'), $segmentos, $Utf8SemBom)

            $argumentos = $inv.pre + @(
                (Join-Path $Root 'falar.py'),
                '--pasta',  $pasta,
                '--voz',    $cfg.voice,
                '--rate',   $rate,
                '--volume', $cfg.volume
            )
            $proc = Start-Process -FilePath $inv.exe -ArgumentList $argumentos -WindowStyle Hidden -PassThru

            # A voz pode ter sido desligada enquanto o audio era gerado.
            if ($RespeitaEnabled -and -not (Get-Config).enabled) { return 'mudo' }

            Set-Controle 'tocar'
            # Comeca em 'fim' e so piora: quem chamou usa isso para decidir se o
            # resumo ja pode sair da fila ou se continua esperando a vez.
            $resultado = 'fim'
            for ($i = 0; $i -lt $segmentos.Count; $i++) {
                # O primeiro pedaco e o unico que espera de verdade; os
                # seguintes ja estao prontos quando chega a vez deles.
                $estado = Wait-SegmentoPronto $pasta $i 120
                if ($estado -ne 'pronto') {
                    if ($estado -eq 'erro') {
                        $msg = try { [System.IO.File]::ReadAllText((Join-Path $pasta 'erro.txt')) } catch { 'desconhecido' }
                        Write-Log "sintese falhou no segmento ${i}: $msg"
                    } elseif ($estado -eq 'timeout') {
                        Write-Log "segmento $i nao ficou pronto no prazo"
                    }
                    $resultado = if ($estado -eq 'cancelado') { 'cancelado' } else { 'erro' }
                    break
                }
                $tocou = Invoke-TocaArquivo (Get-CaminhoSegmento $pasta $i)
                if ($tocou -ne 'fim') { $resultado = $tocou; break }
            }
            Set-Controle 'tocar'
            return $resultado
        } finally {
            # parar.txt antes de matar: se o processo escapar, ele mesmo desiste
            # no proximo segmento em vez de seguir baixando audio perdido.
            try { [System.IO.File]::WriteAllText((Join-Path $pasta 'parar.txt'), '') } catch { }
            if ($proc -and -not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
            Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
            Remove-Item $pasta -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($obteve) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Dispara a fala num processo separado para nao travar o Claude Code.
# O sufixo .nohist no nome do arquivo diz ao processo filho para nao historiar
# de novo um texto que ja foi guardado no historico.
# Dispara um modo do clarisse.ps1 em outro processo. O escutador de atalhos usa
# isso para nao duplicar a logica de leitura: ela vive num lugar so, e o laco de
# mensagens do escutador volta na hora em vez de esperar a fala.
function Start-Modo([string]$modo) {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'clarisse.ps1')`"", '-Mode', $modo `
        -WindowStyle Hidden | Out-Null
}

# O sufixo .fila no nome do arquivo diz ao processo filho que esta fala consome
# um item da fila: se ela chegar ao fim, o resumo sai; se for cortada, volta.
function Start-FalaAssincrona([string]$texto, [switch]$PularHistorico, [switch]$ConsomeFila) {
    if ([string]::IsNullOrWhiteSpace($texto)) { return }
    if (-not (Test-Path $PendDir)) { New-Item -ItemType Directory -Force $PendDir | Out-Null }
    $sufixo = ''
    if ($PularHistorico) { $sufixo += '.nohist' }
    if ($ConsomeFila)    { $sufixo += '.fila' }
    $arq = Join-Path $PendDir ("$([guid]::NewGuid().ToString('N'))$sufixo.txt")
    [System.IO.File]::WriteAllText($arq, $texto, $Utf8SemBom)
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'clarisse.ps1')`"", '-Mode', 'speak', '-File', "`"$arq`"" `
        -WindowStyle Hidden | Out-Null
}
