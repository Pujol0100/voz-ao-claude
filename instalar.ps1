#Requires -Version 5.1
<#
    Instalador da Clarisse - voz para o Claude Code no Windows.

    Uso:
        powershell -ExecutionPolicy Bypass -File .\instalar.ps1

    Opcoes:
        -SemInstrucoes   nao anexa o bloco de instrucoes ao CLAUDE.md
        -Desinstalar     remove hooks, comando e arquivos da Clarisse
#>
param(
    [switch]$SemInstrucoes,
    [switch]$Desinstalar
)

$ErrorActionPreference = 'Stop'
$Origem      = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir   = Join-Path $env:USERPROFILE '.claude'
$DestClarisse = Join-Path $ClaudeDir 'clarisse'
$DestComandos = Join-Path $ClaudeDir 'commands'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$ClaudeMdPath = Join-Path $ClaudeDir 'CLAUDE.md'
$ScriptDest   = Join-Path $DestClarisse 'clarisse.ps1'
$MarcadorIni  = '<!-- clarisse:inicio -->'
$MarcadorFim  = '<!-- clarisse:fim -->'

$Utf8SemBom = New-Object System.Text.UTF8Encoding($false)

function Passo($msg)  { Write-Host "  -> $msg" }
function Aviso($msg)  { Write-Host "  !  $msg" -ForegroundColor Yellow }
function Erro($msg)   { Write-Host "  X  $msg" -ForegroundColor Red }
function Titulo($msg) { Write-Host ""; Write-Host $msg -ForegroundColor Cyan }

function Get-PythonInvocacao {
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
    if ($cmd -and $cmd.Source -and $cmd.Source -notlike '*WindowsApps*') {
        return @{ exe = $cmd.Source; pre = @() }
    }
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        return @{ exe = 'py'; pre = @('-3') }
    }
    return $null
}

function New-EntradaHook([string]$modo, [int]$timeout) {
    return [pscustomobject]@{
        hooks = @(
            [pscustomobject]@{
                type    = 'command'
                command = 'powershell.exe'
                args    = @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $ScriptDest, '-Mode', $modo
                )
                timeout = $timeout
                async   = $true
            }
        )
    }
}

function Test-EhHookClarisse($entrada) {
    foreach ($h in @($entrada.hooks)) {
        if ($h.args -and (@($h.args) -join ' ') -like '*clarisse.ps1*') { return $true }
    }
    return $false
}

# Substitui a entrada da Clarisse mantendo intactos os hooks de terceiros.
function Set-HookEvento($settings, [string]$evento, $entrada) {
    if ($settings.PSObject.Properties.Name -notcontains 'hooks') {
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $existentes = @()
    if ($settings.hooks.PSObject.Properties.Name -contains $evento) {
        $existentes = @($settings.hooks.$evento) | Where-Object { -not (Test-EhHookClarisse $_) }
    }
    $final = @($existentes)
    if ($entrada) { $final = $final + @($entrada) }
    $settings.hooks | Add-Member -NotePropertyName $evento -NotePropertyValue $final -Force
}

# ---------------------------------------------------------------- desinstalar

if ($Desinstalar) {
    Titulo 'Desinstalando a Clarisse'

    if (Test-Path $ScriptDest) {
        try { & $ScriptDest -Mode atalhos-off | Out-Null; Passo 'escutador de atalhos encerrado' } catch { }
    }

    if (Test-Path $SettingsPath) {
        $bkp = "$SettingsPath.bak"
        Copy-Item $SettingsPath $bkp -Force
        Passo "backup do settings.json em $bkp"
        $settings = Get-Content $SettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($ev in @('SessionStart', 'Stop', 'Notification')) {
            Set-HookEvento $settings $ev $null
        }
        ($settings | ConvertTo-Json -Depth 20) | Out-File $SettingsPath -Encoding utf8
        Passo 'hooks removidos do settings.json'
    }

    $cmdPath = Join-Path $DestComandos 'clarisse.md'
    if (Test-Path $cmdPath) { Remove-Item $cmdPath -Force; Passo 'comando /clarisse removido' }

    if (Test-Path $ClaudeMdPath) {
        $md = Get-Content $ClaudeMdPath -Raw -Encoding utf8
        if ($md -like "*$MarcadorIni*") {
            $novo = [regex]::Replace($md, "(?s)\r?\n?$([regex]::Escape($MarcadorIni)).*?$([regex]::Escape($MarcadorFim))\r?\n?", '')
            [System.IO.File]::WriteAllText($ClaudeMdPath, $novo, $Utf8SemBom)
            Passo 'instrucoes removidas do CLAUDE.md'
        }
    }

    if (Test-Path $DestClarisse) {
        Aviso "a pasta $DestClarisse foi mantida (contem seu config e historico). Apague manualmente se quiser."
    }
    Write-Host ''
    Write-Host 'Clarisse desinstalada.' -ForegroundColor Green
    return
}

# ------------------------------------------------------------------ instalar

Titulo 'Instalando a Clarisse'

if (-not (Test-Path $ClaudeDir)) {
    Erro "pasta $ClaudeDir nao existe. O Claude Code esta instalado?"
    exit 1
}

# 1. Python + edge-tts
Titulo '1/5  Python e edge-tts'
$inv = Get-PythonInvocacao
if (-not $inv) {
    Erro 'Python nao encontrado. Instale o Python 3 (python.org) e rode este instalador de novo.'
    exit 1
}
Passo "Python: $($inv.exe)"
$argsInstall = $inv.pre + @('-m', 'pip', 'install', '--quiet', '--upgrade', 'edge-tts')
& $inv.exe @argsInstall
if ($LASTEXITCODE -ne 0) { Erro 'falha ao instalar edge-tts'; exit 1 }
Passo 'edge-tts instalado'

# 2. Arquivos
Titulo '2/5  Arquivos'
New-Item -ItemType Directory -Force $DestClarisse | Out-Null
New-Item -ItemType Directory -Force $DestComandos | Out-Null
New-Item -ItemType Directory -Force (Join-Path $DestClarisse 'entrada') | Out-Null

# Encerra um escutador de versao anterior antes de sobrescrever os scripts.
if (Test-Path $ScriptDest) {
    try { & $ScriptDest -Mode atalhos-off | Out-Null } catch { }
}

foreach ($arq in @('clarisse.ps1', 'nucleo.ps1', 'atalhos.ps1', 'falar.py')) {
    Copy-Item (Join-Path $Origem "clarisse\$arq") (Join-Path $DestClarisse $arq) -Force
}
Passo "motor de voz, nucleo, escutador de atalhos e sintetizador em $DestClarisse"

$destConfig = Join-Path $DestClarisse 'config.json'
if (Test-Path $destConfig) {
    # Config existente e preservado; so ganha os campos que a versao nova exige.
    $atual = Get-Content $destConfig -Raw -Encoding utf8 | ConvertFrom-Json
    $mudou = $false
    if ($atual.PSObject.Properties.Name -notcontains 'atalhos') {
        $atual | Add-Member -NotePropertyName atalhos -NotePropertyValue ([pscustomobject]@{
            ativo = $true; ler = 'Ctrl+Alt+L'; pular = 'Ctrl+Alt+J'
            pausar = 'Ctrl+Alt+P'; cancelar = 'Ctrl+Alt+X'
        }) -Force
        $mudou = $true
        Passo 'config.json ganhou o bloco de atalhos'
    }
    # Quem ja tinha o bloco de atalhos nao tem a tecla de passear pelos projetos.
    if ($atual.atalhos -and ($atual.atalhos.PSObject.Properties.Name -notcontains 'pular')) {
        $atual.atalhos | Add-Member -NotePropertyName pular -NotePropertyValue 'Ctrl+Alt+J' -Force
        $mudou = $true
        Passo 'config.json ganhou a tecla que passeia pelos projetos (Ctrl+Alt+J)'
    }
    if ($atual.PSObject.Properties.Name -notcontains 'triagem') {
        $atual | Add-Member -NotePropertyName triagem -NotePropertyValue $true -Force
        $mudou = $true
        Passo 'config.json ganhou a triagem falada (desligue com "triagem": false)'
    }
    if ($atual.maxChars -lt 1800) {
        $atual.maxChars = 1800
        $mudou = $true
        Passo 'config.json: limite da fala ampliado para 1800 caracteres'
    }
    if ($mudou) { $atual | ConvertTo-Json -Depth 5 | Out-File $destConfig -Encoding utf8 }
    else        { Passo 'config.json ja estava atualizado - mantido como esta' }
} else {
    Copy-Item (Join-Path $Origem 'clarisse\config.json') $destConfig -Force
    Passo 'config.json criado com os padroes'
}

Copy-Item (Join-Path $Origem 'comandos\clarisse.md') (Join-Path $DestComandos 'clarisse.md') -Force
Passo 'comando /clarisse instalado'

# 3. Hooks
Titulo '3/5  Hooks do Claude Code'
if (Test-Path $SettingsPath) {
    $bkp = "$SettingsPath.bak"
    Copy-Item $SettingsPath $bkp -Force
    Passo "backup do settings.json em $bkp"
    $settings = Get-Content $SettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
} else {
    $settings = [pscustomobject]@{}
    Passo 'settings.json criado do zero'
}

Set-HookEvento $settings 'SessionStart' (New-EntradaHook 'autostart' 10)
Set-HookEvento $settings 'Stop'         (New-EntradaHook 'stop'      15)
Set-HookEvento $settings 'Notification' (New-EntradaHook 'notify'    15)
($settings | ConvertTo-Json -Depth 20) | Out-File $SettingsPath -Encoding utf8

try {
    Get-Content $SettingsPath -Raw -Encoding utf8 | ConvertFrom-Json | Out-Null
    Passo 'hooks SessionStart, Stop e Notification gravados'
} catch {
    Erro 'settings.json ficou invalido - restaurando backup'
    Copy-Item "$SettingsPath.bak" $SettingsPath -Force
    exit 1
}

# 4. Instrucoes no CLAUDE.md
Titulo '4/5  Instrucoes para o Claude'
if ($SemInstrucoes) {
    Aviso 'pulado (-SemInstrucoes). Sem isso a Clarisse fica muda: nada escreve o resumo em fala.txt.'
} else {
    $bloco = Get-Content (Join-Path $Origem 'docs\INSTRUCOES-CLAUDE.md') -Raw -Encoding utf8
    $bloco = $bloco.Replace('{{CLARISSE_DIR}}', $DestClarisse)
    $md = ''
    if (Test-Path $ClaudeMdPath) { $md = Get-Content $ClaudeMdPath -Raw -Encoding utf8 }
    if ($md -like "*$MarcadorIni*") {
        $md = [regex]::Replace($md, "(?s)$([regex]::Escape($MarcadorIni)).*?$([regex]::Escape($MarcadorFim))", "$MarcadorIni`n$bloco`n$MarcadorFim")
        Passo 'bloco de instrucoes atualizado no CLAUDE.md'
        [System.IO.File]::WriteAllText($ClaudeMdPath, $md, $Utf8SemBom)
    } elseif ($md -match '(?m)^#+\s*Clarisse\b') {
        # Bloco colado a mao, sem os marcadores: anexar criaria uma segunda copia
        # e o Claude passaria a receber duas instrucoes conflitantes.
        Aviso 'ja existe um bloco da Clarisse no CLAUDE.md, mas sem os marcadores clarisse:inicio/clarisse:fim.'
        Aviso 'apague esse bloco a mao e rode o instalador de novo - nada foi escrito no CLAUDE.md.'
    } else {
        $md = $md.TrimEnd() + "`n`n$MarcadorIni`n$bloco`n$MarcadorFim`n"
        Passo 'bloco de instrucoes anexado ao CLAUDE.md'
        [System.IO.File]::WriteAllText($ClaudeMdPath, $md, $Utf8SemBom)
    }
}

# 5. Teste
Titulo '5/5  Atalhos e teste de voz'
& $ScriptDest -Mode atalhos-on
& $ScriptDest -Mode test

Write-Host ''
Write-Host 'Instalacao concluida.' -ForegroundColor Green
Write-Host 'Abra /hooks uma vez no Claude Code (ou reinicie) para os hooks entrarem em vigor.'
Write-Host ''
Write-Host 'Ctrl+Alt+L  ler o resumo - com varios projetos esperando, anuncia quem sao'
Write-Host 'Ctrl+Alt+J  passear para o proximo projeto da fila'
Write-Host 'Ctrl+Alt+P  pausar e retomar do mesmo ponto'
Write-Host 'Ctrl+Alt+X  cancelar a fala - o resumo volta para a fila'
Write-Host ''
Write-Host 'Quando o Claude terminar, voce ouve um bipe curto - a fala so sai no Ctrl+Alt+L.'
Write-Host 'Use /clarisse status, /clarisse atalhos off, /clarisse repetir.'
