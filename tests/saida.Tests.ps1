# O Invoke-Fala passou a devolver o estado final da fala, para o modo speak saber
# se o resumo pode sair da fila. Efeito colateral: todo chamador que ignora esse
# retorno deixa o valor cair no pipeline e ele aparece na tela.
#
# Foi assim que a instalacao imprimiu um "fim" solto entre as mensagens, e o
# /clarisse - que promete responder em uma linha - passou a responder em duas.
# Estes testes olham o codigo em vez de rodar a fala, porque verificar de verdade
# exigiria gerar audio a cada execucao da suite.

$raizClarisse = Join-Path $PSScriptRoot '..\clarisse'

function Get-LinhasDeCodigo([string]$arquivo) {
    $texto = [System.IO.File]::ReadAllText($arquivo, [System.Text.Encoding]::UTF8)
    return @($texto -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
}

Describe 'saida dos modos do clarisse.ps1' {

    It 'nenhuma chamada a Invoke-Fala deixa o retorno solto no pipeline' {
        $soltas = New-Object System.Collections.ArrayList
        foreach ($linha in (Get-LinhasDeCodigo (Join-Path $raizClarisse 'clarisse.ps1'))) {
            if ($linha -notmatch 'Invoke-Fala') { continue }
            # Formas aceitaveis: descartar com Out-Null, guardar em variavel, ou
            # usar o valor numa comparacao.
            $tratada = ($linha -match 'Out-Null') -or
                       ($linha -match '\$\w+\s*=') -or
                       ($linha -match '^\s*(else|if)\s')
            if (-not $tratada) { [void]$soltas.Add($linha.Trim()) }
        }
        ($soltas.ToArray() -join ' || ') | Should BeNullOrEmpty
    }

    It 'a mensagem de atalhos ativos cita as quatro teclas' {
        # Sem isso o usuario instala, ve tres teclas na tela e nao descobre a
        # que passeia pelos projetos - o recurso existe e fica invisivel.
        $texto = [System.IO.File]::ReadAllText((Join-Path $raizClarisse 'clarisse.ps1'), [System.Text.Encoding]::UTF8)
        $bloco = [regex]::Match($texto, "Clarisse: atalhos ativos[^`r`n]*")
        $bloco.Success | Should Be $true
        $bloco.Value | Should Match 'atalhos\.ler'
        $bloco.Value | Should Match 'atalhos\.pular'
        $bloco.Value | Should Match 'atalhos\.pausar'
        $bloco.Value | Should Match 'atalhos\.cancelar'
    }
}

Describe 'saida do instalador' {

    It 'o resumo final cita a tecla que passeia pelos projetos' {
        # Procura na lista de teclas que o instalador imprime no fim, e nao no
        # arquivo inteiro: a primeira versao deste teste passava por casar com a
        # string usada na migracao do config, sem provar nada sobre a mensagem.
        $texto = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\instalar.ps1'), [System.Text.Encoding]::UTF8)
        $texto | Should Match "Write-Host 'Ctrl\+Alt\+J"
    }
}
