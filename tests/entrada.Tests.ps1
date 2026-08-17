# Testes da caixa de entrada por projeto.
#
# O resumo que o Claude escreve nao pode ir para um arquivo unico: as sessoes
# compartilham a pasta e uma sobrescreve o resumo da outra antes do hook ler.
# Cada projeto escreve na sua caixa, e o nome do arquivo e a fonte da verdade
# sobre a origem - nao importa qual sessao dispara o hook que recolhe.

$ClarisseRoot = Join-Path $env:TEMP ("clarisse-entrada-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $ClarisseRoot | Out-Null

. (Join-Path $PSScriptRoot '..\clarisse\nucleo.ps1')

function Reset-Tudo {
    foreach ($d in @($FilaDir, $EntradaDir)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    Remove-Item $PendenteLegado -Force -ErrorAction SilentlyContinue
    Remove-Item $FalaPath -Force -ErrorAction SilentlyContinue
}

function Escrever-Entrada($projeto, $texto) {
    if (-not (Test-Path $EntradaDir)) { New-Item -ItemType Directory -Force $EntradaDir | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $EntradaDir "$projeto.txt"), $texto, $Utf8SemBom)
}

Describe 'Get-CaminhoEntrada' {
    It 'da uma caixa por projeto' {
        Get-CaminhoEntrada 'voz-ao-claude' | Should Be (Join-Path $EntradaDir 'voz-ao-claude.txt')
    }
    It 'troca caractere proibido em nome de arquivo' {
        Get-CaminhoEntrada 'meu:projeto*ruim' | Should Be (Join-Path $EntradaDir 'meu-projeto-ruim.txt')
    }
    It 'devolve vazio sem projeto' {
        Get-CaminhoEntrada '' | Should BeNullOrEmpty
    }
}

Describe 'Import-Entradas' {
    It 'nao faz nada com a caixa vazia' {
        Reset-Tudo
        (Import-Entradas).Count | Should Be 0
        Get-PendenteCount       | Should Be 0
    }

    It 'recolhe um resumo e tira o projeto do nome do arquivo' {
        Reset-Tudo
        Escrever-Entrada 'voz-ao-claude' 'Rodei os testes.'
        $novos = Import-Entradas
        $novos.Count       | Should Be 1
        $novos[0].projeto  | Should Be 'voz-ao-claude'
        $novos[0].texto    | Should Be 'Rodei os testes.'
        Get-PendenteCount  | Should Be 1
    }

    It 'recolhe os resumos de varios projetos de uma vez' {
        Reset-Tudo
        Escrever-Entrada 'projeto-a' 'resumo do a'
        Escrever-Entrada 'projeto-b' 'resumo do b'
        Escrever-Entrada 'projeto-c' 'resumo do c'
        (Import-Entradas).Count | Should Be 3
        Get-PendenteCount       | Should Be 3
        (Get-ProjetosNaFila) -contains 'projeto-b' | Should Be $true
    }

    It 'esvazia a caixa depois de recolher' {
        Reset-Tudo
        Escrever-Entrada 'projeto-a' 'resumo'
        Import-Entradas | Out-Null
        (Get-ChildItem $EntradaDir -Filter '*.txt' -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'nao recolhe duas vezes o mesmo resumo' {
        Reset-Tudo
        Escrever-Entrada 'projeto-a' 'resumo'
        Import-Entradas | Out-Null
        (Import-Entradas).Count | Should Be 0
        Get-PendenteCount       | Should Be 1
    }

    It 'descarta caixa em branco sem enfileirar nada' {
        Reset-Tudo
        Escrever-Entrada 'projeto-a' "   `n  "
        (Import-Entradas).Count | Should Be 0
        Get-PendenteCount       | Should Be 0
        (Get-ChildItem $EntradaDir -Filter '*.txt' -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'preserva acento e quebra de linha' {
        Reset-Tudo
        Escrever-Entrada 'projeto-a' "Conclui a analise.`nFaltam duas pendencias."
        (Import-Entradas)[0].texto | Should Match 'Faltam duas pendencias'
    }

    It 'recolhe um fala.txt da versao antiga sem chutar de quem e' {
        Reset-Tudo
        [System.IO.File]::WriteAllText($FalaPath, 'resumo sem dono', $Utf8SemBom)
        $novos = Import-Entradas
        $novos.Count      | Should Be 1
        $novos[0].projeto | Should BeNullOrEmpty
        $novos[0].texto   | Should Be 'resumo sem dono'
        Test-Path $FalaPath | Should Be $false
    }

    It 'recolhe caixa por projeto e fala.txt antigo na mesma passada' {
        Reset-Tudo
        Escrever-Entrada 'projeto-a' 'resumo com dono'
        [System.IO.File]::WriteAllText($FalaPath, 'resumo sem dono', $Utf8SemBom)
        (Import-Entradas).Count | Should Be 2
        Get-PendenteCount       | Should Be 2
    }

    It 'a fala do resumo recolhido anuncia o projeto certo' {
        Reset-Tudo
        Escrever-Entrada 'omni-api' 'Abri os dois pull requests.'
        Import-Entradas | Out-Null
        Format-FalaPendente (Read-Pendente) | Should Be 'No projeto omni-api: Abri os dois pull requests.'
    }
}

Remove-Item $ClarisseRoot -Recurse -Force -ErrorAction SilentlyContinue
