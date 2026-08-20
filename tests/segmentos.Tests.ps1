# Testes da segmentacao do texto em pedacos para sintese progressiva.
#
# Por que existe: gerar o audio do resumo inteiro antes de tocar a primeira nota
# custa 33 segundos de silencio, mas o primeiro pedaco de audio fica pronto em
# pouco mais de um segundo. Segmentar deixa a fala comecar quase na hora, e o
# resto e sintetizado enquanto ela fala - sintetizar e 3 vezes mais rapido do
# que falar, entao nunca engasga depois do primeiro pedaco.
#
# A segmentacao vive aqui, no PowerShell, e nao no script Python: assim toda a
# logica que pode errar onde cortar e testavel sem gerar um byte de audio.

$ClarisseRoot = Join-Path $env:TEMP ("clarisse-seg-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $ClarisseRoot | Out-Null

. (Join-Path $PSScriptRoot '..\clarisse\nucleo.ps1')

function Get-Palavras([string]$t) {
    return @($t -split '\s+' | Where-Object { $_ })
}

Describe 'Split-EmSegmentos' {

    It 'devolve nada para texto vazio ou em branco' {
        @(Split-EmSegmentos -Texto ''    -PrimeiroMax 100 -DemaisMax 300).Count | Should Be 0
        @(Split-EmSegmentos -Texto '   ' -PrimeiroMax 100 -DemaisMax 300).Count | Should Be 0
    }

    It 'devolve um unico segmento quando o texto e uma frase curta' {
        $segs = @(Split-EmSegmentos -Texto 'Rodei os quarenta testes.' -PrimeiroMax 100 -DemaisMax 300)
        $segs.Count | Should Be 1
        $segs[0]    | Should Be 'Rodei os quarenta testes.'
    }

    It 'mantem o primeiro segmento curto mesmo quando o texto e longo' {
        # Este e o teste que justifica a mudanca inteira: o primeiro pedaco e o
        # que define quanto tempo o usuario espera em silencio.
        $texto = 'Primeira frase bem curta. ' + ('Mais uma frase de tamanho normal para encher. ' * 20)
        $segs = @(Split-EmSegmentos -Texto $texto -PrimeiroMax 100 -DemaisMax 300)
        $segs.Count            | Should BeGreaterThan 1
        $segs[0].Length        | Should BeLessThan 101
        $segs[0]               | Should Match '^Primeira frase bem curta\.'
    }

    It 'nenhum segmento passa do limite pedido' {
        $texto = ('Uma frase de tamanho razoavel para o teste. ' * 30)
        $segs = @(Split-EmSegmentos -Texto $texto -PrimeiroMax 100 -DemaisMax 300)
        $segs[0].Length | Should BeLessThan 101
        foreach ($s in $segs[1..($segs.Count - 1)]) {
            $s.Length | Should BeLessThan 301
        }
    }

    It 'agrupa frases curtas em vez de gerar um segmento por frase' {
        # Cada segmento custa uma ida ao servidor de voz: fragmentar demais
        # torna a sintese mais lenta que a fala e a voz engasga entre frases.
        $texto = 'Primeira frase curta. ' + ('Curta. ' * 40)
        $segs = @(Split-EmSegmentos -Texto $texto -PrimeiroMax 100 -DemaisMax 300)
        $segs.Count | Should BeLessThan 8
    }

    It 'nao parte numero decimal no meio' {
        $segs = @(Split-EmSegmentos -Texto 'O total ficou em 1.500 reais no fechamento.' -PrimeiroMax 100 -DemaisMax 300)
        $segs.Count | Should Be 1
        $segs[0]    | Should Match '1\.500'
    }

    It 'quebra texto longo que nao tem pontuacao nenhuma' {
        # Sem isso o primeiro segmento seria o texto inteiro e a espera voltaria.
        $texto = ('palavra ' * 200).Trim()
        $segs = @(Split-EmSegmentos -Texto $texto -PrimeiroMax 100 -DemaisMax 300)
        $segs.Count     | Should BeGreaterThan 1
        $segs[0].Length | Should BeLessThan 101
    }

    It 'nao perde nem duplica nenhuma palavra do texto original' {
        $texto = 'Rodei os quarenta testes e trinta e oito passaram. Dois falharam na conversao de data! Preciso de uma decisao sua; o desconto entra antes ou depois?'
        $segs = @(Split-EmSegmentos -Texto $texto -PrimeiroMax 100 -DemaisMax 300)
        (Get-Palavras ($segs -join ' ')) -join '|' | Should Be ((Get-Palavras $texto) -join '|')
    }

    It 'nunca devolve segmento vazio ou so com espaco' {
        $texto = 'Frase uma.   Frase dois.     Frase tres.  ' + ('Enchendo o texto para forcar varios pedacos. ' * 15)
        $segs = @(Split-EmSegmentos -Texto $texto -PrimeiroMax 100 -DemaisMax 300)
        foreach ($s in $segs) {
            $s | Should Not BeNullOrEmpty
            $s.Trim().Length | Should BeGreaterThan 0
        }
    }
}

Describe 'Split-EmSegmentos: forma do retorno' {
    # O bug que passou pelos testes: a funcao devolvia o array embrulhado, e
    # quem chama envolve em @(). Os dois juntos davam um array dentro de um
    # array, entao o texto inteiro virava um unico segmento e a espera de trinta
    # e tres segundos voltava - com a suite toda verde, porque os testes
    # chamavam com parenteses e a producao chama com @().
    #
    # Licao: o teste tem de chamar do mesmo jeito que o codigo de verdade chama.
    It 'devolve strings, nunca um array aninhado' {
        $segs = @(Split-EmSegmentos -Texto 'Primeira frase. Segunda frase.' -PrimeiroMax 20 -DemaisMax 20)
        foreach ($s in $segs) {
            $s -is [string] | Should Be $true
        }
    }

    It 'devolve string tambem quando o resultado tem um unico segmento' {
        $segs = @(Split-EmSegmentos -Texto 'Frase unica.' -PrimeiroMax 100 -DemaisMax 300)
        $segs.Count     | Should Be 1
        $segs[0] -is [string] | Should Be $true
        $segs[0].Length | Should Be 12
    }

    It 'reparte um resumo de tamanho real em varios pedacos' {
        # Tamanho tipico de um resumo falado, com os limites de producao.
        $resumo = ('Rodei os testes e todos passaram sem falha nenhuma. ' * 12)
        $segs = @(Split-EmSegmentos -Texto $resumo)
        $segs.Count     | Should BeGreaterThan 2
        $segs[0].Length | Should BeLessThan 111
    }
}