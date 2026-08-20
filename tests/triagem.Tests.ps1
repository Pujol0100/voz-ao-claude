# Testes da fila que nao destroi resumo e da triagem falada.
#
# O defeito que isto corrige: Read-Pendente apagava o arquivo do disco antes de
# a fala comecar, e sempre entregava o mais recente, sem jeito de escolher. Para
# ouvir o resumo de um projeto especifico era preciso passar por todos os outros
# - destruindo cada um no caminho. Cancelar ao perceber que era o projeto errado
# perdia aquele resumo de vez.

$ClarisseRoot = Join-Path $env:TEMP ("clarisse-triagem-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $ClarisseRoot | Out-Null

. (Join-Path $PSScriptRoot '..\clarisse\nucleo.ps1')

function Reset-Tudo {
    if (Test-Path $FilaDir) { Remove-Item $FilaDir -Recurse -Force }
    Remove-Item $EmLeituraPath -Force -ErrorAction SilentlyContinue
    Remove-Item $SelecaoPath   -Force -ErrorAction SilentlyContinue
}

Describe 'fila que nao destroi o resumo nao ouvido' {

    It 'nao apaga o resumo ao entregar: ele so sai da fila quando a fala termina' {
        Reset-Tudo
        Add-Pendente 'Resumo unico.' 'projeto-a'
        $item = Read-Pendente
        $item.texto       | Should Be 'Resumo unico.'
        Get-PendenteCount | Should Be 1
        Complete-Leitura
        Get-PendenteCount | Should Be 0
    }

    It 'devolve o resumo para a fila quando a leitura e abortada' {
        # O caso real: voce ouve "no projeto tal", ve que nao e o que queria e
        # aperta Ctrl+Alt+X. Antes, aquele resumo estava perdido.
        Reset-Tudo
        Add-Pendente 'Resumo que nao quero agora.' 'projeto-a'
        Read-Pendente | Out-Null
        Abort-Leitura
        Get-PendenteCount     | Should Be 1
        (Read-Pendente).texto | Should Be 'Resumo que nao quero agora.'
    }

    It 'recupera sozinha o resumo de uma leitura que morreu no meio' {
        # Se o processo que falava foi morto, ninguem chamou Complete nem Abort.
        # O resumo tem de voltar para a fila, nunca ficar preso.
        Reset-Tudo
        Add-Pendente 'Resumo orfao.' 'projeto-a'
        Read-Pendente | Out-Null
        # nada de Complete nem Abort: simula o processo morto
        Get-PendenteCount     | Should Be 1
        (Read-Pendente).texto | Should Be 'Resumo orfao.'
    }

    It 'nao conta o resumo como pendente duas vezes depois de concluido' {
        Reset-Tudo
        Add-Pendente 'a' 'projeto-a'
        Add-Pendente 'b' 'projeto-b'
        Read-Pendente | Out-Null
        Complete-Leitura
        Get-PendenteCount | Should Be 1
        Read-Pendente | Out-Null
        Complete-Leitura
        Get-PendenteCount | Should Be 0
    }
}

Describe 'Read-Pendente -Projeto' {

    It 'entrega o resumo do projeto pedido, e nao o mais recente' {
        Reset-Tudo
        Add-Pendente 'Da conciliacao.' 'conciliacao-bancaria'
        Add-Pendente 'Do velocimetro.' 'velocimetro-tokens'
        $item = Read-Pendente -Projeto 'conciliacao-bancaria'
        $item.texto   | Should Be 'Da conciliacao.'
        $item.projeto | Should Be 'conciliacao-bancaria'
    }

    It 'aceita nome parcial, para nao ser preciso digitar o nome inteiro' {
        Reset-Tudo
        Add-Pendente 'Da conciliacao.' 'conciliacao-bancaria'
        Add-Pendente 'Do velocimetro.' 'velocimetro-tokens'
        (Read-Pendente -Projeto 'concil').texto | Should Be 'Da conciliacao.'
    }

    It 'ignora diferenca de maiuscula e minuscula' {
        Reset-Tudo
        Add-Pendente 'Do omni.' 'omni-api'
        (Read-Pendente -Projeto 'OMNI').texto | Should Be 'Do omni.'
    }

    It 'entrega o mais recente quando o projeto deixou varios resumos' {
        Reset-Tudo
        Add-Pendente 'antigo' 'omni-api'
        Add-Pendente 'outro projeto' 'velocimetro-tokens'
        Add-Pendente 'novo' 'omni-api'
        (Read-Pendente -Projeto 'omni-api').texto | Should Be 'novo'
    }

    It 'devolve nada quando o projeto pedido nao tem resumo na fila' {
        Reset-Tudo
        Add-Pendente 'Do omni.' 'omni-api'
        Read-Pendente -Projeto 'projeto-que-nao-existe' | Should BeNullOrEmpty
        # e nao pode ter consumido nem marcado nada
        Get-PendenteCount | Should Be 1
    }

    It 'nao deixa o resumo do projeto errado marcado como em leitura' {
        Reset-Tudo
        Add-Pendente 'Da conciliacao.' 'conciliacao-bancaria'
        Add-Pendente 'Do velocimetro.' 'velocimetro-tokens'
        Read-Pendente -Projeto 'concil' | Out-Null
        Complete-Leitura
        (Get-ProjetosNaFila) -join ',' | Should Be 'velocimetro-tokens'
    }
}

Describe 'Get-ResumoDaFila' {

    It 'conta quantos resumos cada projeto deixou, do mais recente para o mais antigo' {
        Reset-Tudo
        Add-Pendente 'a1' 'omni-api'
        Add-Pendente 'v1' 'velocimetro-tokens'
        Add-Pendente 'a2' 'omni-api'
        $r = @(Get-ResumoDaFila)
        $r.Count           | Should Be 2
        $r[0].projeto      | Should Be 'omni-api'
        $r[0].quantos      | Should Be 2
        $r[1].projeto      | Should Be 'velocimetro-tokens'
        $r[1].quantos      | Should Be 1
    }

    It 'devolve nada com a fila vazia' {
        Reset-Tudo
        @(Get-ResumoDaFila).Count | Should Be 0
    }
}

Describe 'Format-FalaTriagem' {
    # Medido com a fila real do usuario: listando seis projetos com a contagem de
    # cada um, a frase dava 334 caracteres - uns 25 segundos so para anunciar a
    # lista, antes de comecar a ler qualquer resumo. Ouvir isso a cada leitura
    # seria pior que o problema que a triagem resolve. Por isso a frase diz os
    # totais e os nomes, nao a contagem de cada projeto, e cita no maximo cinco.

    It 'diz quantos projetos esperam e quantos resumos ha no total' {
        $fala = Format-FalaTriagem @(
            @{ projeto = 'conciliacao-bancaria'; quantos = 3 },
            @{ projeto = 'omni-api';             quantos = 1 }
        )
        $fala | Should Match 'dois projetos'
        $fala | Should Match 'quatro resumos'
        $fala | Should Match 'conciliacao'
        $fala | Should Match 'omni'
    }

    It 'liga o ultimo nome com "e" em vez de virgula' {
        $fala = Format-FalaTriagem @(
            @{ projeto = 'alfa';  quantos = 1 },
            @{ projeto = 'beta';  quantos = 1 },
            @{ projeto = 'gama';  quantos = 1 }
        )
        $fala | Should Match 'alfa, beta e gama'
    }

    It 'troca hifen por espaco para a voz nao soletrar o nome da pasta' {
        $fala = Format-FalaTriagem @(
            @{ projeto = 'velocimetro-tokens'; quantos = 1 },
            @{ projeto = 'omni-api';           quantos = 1 }
        )
        $fala | Should Not Match '-'
        $fala | Should Match 'velocimetro tokens'
    }

    It 'usa singular quando ha um resumo so' {
        $fala = Format-FalaTriagem @(
            @{ projeto = 'omni-api'; quantos = 1 },
            @{ projeto = 'alfa';     quantos = 1 }
        )
        $fala | Should Match 'dois resumos'
    }

    It 'cita no maximo cinco projetos e resume o resto' {
        $muitos = @(
            @{ projeto = 'um';    quantos = 1 }, @{ projeto = 'dois';  quantos = 1 },
            @{ projeto = 'tres';  quantos = 1 }, @{ projeto = 'quatro'; quantos = 1 },
            @{ projeto = 'cinco'; quantos = 1 }, @{ projeto = 'seis';  quantos = 1 },
            @{ projeto = 'sete';  quantos = 1 }
        )
        $fala = Format-FalaTriagem $muitos
        $fala | Should Match 'sete projetos'
        $fala | Should Match 'cinco'
        $fala | Should Not Match '\bseis\b.*\bsete\b'
        $fala | Should Match 'mais dois'
    }

    It 'cabe no ouvido: nao passa de 220 caracteres nem com muitos projetos' {
        # Orcamento de tamanho, para o formato nao voltar a crescer sem medida.
        $seis = @(
            @{ projeto = 'compliance-app';       quantos = 3 },
            @{ projeto = 'velocimetro-tokens';   quantos = 6 },
            @{ projeto = 'consultor-financeiro'; quantos = 2 },
            @{ projeto = 'conciliacao-bancaria'; quantos = 3 },
            @{ projeto = 'omni-api';             quantos = 3 },
            @{ projeto = 'PROGRAMASSMART';       quantos = 3 }
        )
        (Format-FalaTriagem $seis).Length | Should BeLessThan 221
    }

    It 'devolve vazio quando nao ha nada esperando' {
        Format-FalaTriagem @() | Should BeNullOrEmpty
    }
}

Describe 'modo selecao com o teclado' {

    It 'comeca no projeto mais recente da fila' {
        Reset-Tudo
        Add-Pendente 'a' 'omni-api'
        Add-Pendente 'v' 'velocimetro-tokens'
        Start-Selecao   | Should Be 'velocimetro-tokens'
        Get-Selecao     | Should Be 'velocimetro-tokens'
    }

    It 'avanca para o proximo projeto e da a volta no fim da lista' {
        Reset-Tudo
        Add-Pendente 'a' 'projeto-a'
        Add-Pendente 'b' 'projeto-b'
        Add-Pendente 'c' 'projeto-c'
        Start-Selecao        | Should Be 'projeto-c'
        Move-Selecao         | Should Be 'projeto-b'
        Move-Selecao         | Should Be 'projeto-a'
        Move-Selecao         | Should Be 'projeto-c'
    }

    It 'nao consome nem apaga nada ao passear pelos projetos' {
        Reset-Tudo
        Add-Pendente 'a' 'projeto-a'
        Add-Pendente 'b' 'projeto-b'
        Start-Selecao | Out-Null
        Move-Selecao  | Out-Null
        Move-Selecao  | Out-Null
        Get-PendenteCount | Should Be 2
    }

    It 'esquece a selecao quando o usuario sai dela' {
        Reset-Tudo
        Add-Pendente 'a' 'projeto-a'
        Start-Selecao | Out-Null
        Clear-Selecao
        Get-Selecao | Should BeNullOrEmpty
    }

    It 'nao devolve selecao de projeto que ja saiu da fila' {
        # A selecao expira junto com o motivo dela existir.
        Reset-Tudo
        Add-Pendente 'a' 'projeto-a'
        Start-Selecao | Out-Null
        Read-Pendente -Projeto 'projeto-a' | Out-Null
        Complete-Leitura
        Get-Selecao | Should BeNullOrEmpty
    }

    It 'devolve nada quando a fila esta vazia' {
        Reset-Tudo
        Start-Selecao | Should BeNullOrEmpty
    }
}

Describe 'numero por extenso na fala' {
    # A fila tem teto de 20 resumos, e digito solto na fala sai lido de formas
    # imprevisiveis. A tabela precisa cobrir a faixa que aparece de verdade.
    It 'escreve por extenso todo numero que a fila pode produzir' {
        foreach ($n in 1..20) {
            (Get-PorExtenso $n) | Should Not Match '^\d+$'
        }
    }

    It 'diz vinte resumos, nao o digito' {
        $vinte = @(
            @{ projeto = 'alfa'; quantos = 10 },
            @{ projeto = 'beta'; quantos = 10 }
        )
        $fala = Format-FalaTriagem $vinte
        $fala | Should Match 'vinte resumos'
        $fala | Should Not Match '\d'
    }

    It 'diz "mais um projeto", nao "mais um" solto' {
        $muitos = @(
            @{ projeto = 'um';    quantos = 1 }, @{ projeto = 'dois';  quantos = 1 },
            @{ projeto = 'tres';  quantos = 1 }, @{ projeto = 'quatro'; quantos = 1 },
            @{ projeto = 'cinco'; quantos = 1 }, @{ projeto = 'seis';  quantos = 1 }
        )
        Format-FalaTriagem $muitos | Should Match 'mais um projeto'
    }

    It 'diz "mais dois projetos" no plural' {
        $muitos = @(
            @{ projeto = 'um';    quantos = 1 }, @{ projeto = 'dois';  quantos = 1 },
            @{ projeto = 'tres';  quantos = 1 }, @{ projeto = 'quatro'; quantos = 1 },
            @{ projeto = 'cinco'; quantos = 1 }, @{ projeto = 'seis';  quantos = 1 },
            @{ projeto = 'sete';  quantos = 1 }
        )
        Format-FalaTriagem $muitos | Should Match 'mais dois projetos'
    }
}