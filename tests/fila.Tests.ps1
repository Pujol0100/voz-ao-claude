# Testes da fila de resumos pendentes, que precisa aguentar varias sessoes do
# Claude Code escrevendo ao mesmo tempo sem uma apagar o resumo da outra.

$ClarisseRoot = Join-Path $env:TEMP ("clarisse-fila-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $ClarisseRoot | Out-Null

. (Join-Path $PSScriptRoot '..\clarisse\nucleo.ps1')

function Reset-Fila {
    if (Test-Path $FilaDir) { Remove-Item $FilaDir -Recurse -Force }
    Remove-Item $PendenteLegado -Force -ErrorAction SilentlyContinue
}

Describe 'fila de resumos' {
    It 'comeca vazia' {
        Reset-Fila
        Test-Pendente        | Should Be $false
        Get-PendenteCount    | Should Be 0
        Read-Pendente        | Should BeNullOrEmpty
    }

    It 'guarda dois resumos de projetos diferentes sem um apagar o outro' {
        Reset-Fila
        Add-Pendente 'Rodei os testes.' 'voz-ao-claude'
        Add-Pendente 'Implementei a cadeia.' 'cadeia-sequencial'
        Get-PendenteCount | Should Be 2
    }

    It 'entrega o mais recente primeiro, com projeto e quantos faltam' {
        Reset-Fila
        Add-Pendente 'Resumo antigo.' 'projeto-a'
        Add-Pendente 'Resumo novo.'   'projeto-b'
        $item = Read-Pendente
        $item.texto     | Should Be 'Resumo novo.'
        $item.projeto   | Should Be 'projeto-b'
        $item.restantes | Should Be 1
    }

    It 'consome o que entregou' {
        Reset-Fila
        Add-Pendente 'unico' 'projeto-a'
        (Read-Pendente).texto | Should Be 'unico'
        Get-PendenteCount     | Should Be 0
        Read-Pendente         | Should BeNullOrEmpty
    }

    It 'esvazia na ordem do mais novo para o mais velho' {
        Reset-Fila
        1..3 | ForEach-Object { Add-Pendente "resumo $_" "projeto-$_" }
        (Read-Pendente).texto | Should Be 'resumo 3'
        (Read-Pendente).texto | Should Be 'resumo 2'
        (Read-Pendente).texto | Should Be 'resumo 1'
        Get-PendenteCount     | Should Be 0
    }

    It 'ignora resumo em branco' {
        Reset-Fila
        Add-Pendente '   ' 'projeto-a'
        Get-PendenteCount | Should Be 0
    }

    It 'preserva acento e quebra de linha no texto' {
        Reset-Fila
        Add-Pendente "Conclui a analise.`nFaltam duas pendencias." 'projeto-acentuado'
        (Read-Pendente).texto | Should Match 'Faltam duas pendencias'
    }

    It 'descarta os mais velhos quando passa do teto de vinte' {
        Reset-Fila
        1..25 | ForEach-Object { Add-Pendente "resumo $_" 'projeto-a' }
        Get-PendenteCount     | Should Be 20
        (Read-Pendente).texto | Should Be 'resumo 25'
    }

    It 'aproveita um pendente.txt da versao antiga' {
        Reset-Fila
        [System.IO.File]::WriteAllText($PendenteLegado, 'resumo da versao antiga')
        Get-PendenteCount     | Should Be 1
        (Read-Pendente).texto | Should Be 'resumo da versao antiga'
        Test-Path $PendenteLegado | Should Be $false
    }
}

Describe 'Format-FalaPendente' {
    It 'anuncia o projeto antes do texto' {
        $r = Format-FalaPendente @{ projeto = 'voz-ao-claude'; texto = 'Os testes passaram.'; restantes = 0 }
        $r | Should Be 'No projeto voz-ao-claude: Os testes passaram.'
    }
    It 'avisa no singular quando falta um' {
        $r = Format-FalaPendente @{ projeto = 'p'; texto = 'Feito.'; restantes = 1 }
        $r | Should Match 'Tem mais um resumo esperando\.$'
    }
    It 'avisa por extenso quando faltam varios' {
        $r = Format-FalaPendente @{ projeto = 'p'; texto = 'Feito.'; restantes = 3 }
        $r | Should Match 'Tem mais tres resumos esperando\.$'
    }
    It 'usa o numero quando a fila e grande demais para o extenso' {
        $r = Format-FalaPendente @{ projeto = 'p'; texto = 'Feito.'; restantes = 14 }
        $r | Should Match 'Tem mais 14 resumos esperando\.$'
    }
    It 'nao inventa projeto quando nao sabe de onde veio' {
        $r = Format-FalaPendente @{ projeto = ''; texto = 'Os testes passaram.'; restantes = 0 }
        $r | Should Be 'Os testes passaram.'
    }
}

Describe 'Get-NomeProjeto' {
    It 'usa o nome da pasta do projeto' {
        Get-NomeProjeto 'C:\Users\alguem\Documentos\voz-ao-claude' | Should Be 'voz-ao-claude'
    }
    It 'ignora a barra final' {
        Get-NomeProjeto 'C:\Users\alguem\meu-projeto\' | Should Be 'meu-projeto'
    }
    It 'devolve vazio quando nao recebe nada' {
        Get-NomeProjeto '' | Should BeNullOrEmpty
    }
}

Describe 'Get-ProjetosNaFila' {
    It 'lista os projetos do mais recente para o mais antigo' {
        Reset-Fila
        Add-Pendente 'a' 'projeto-a'
        Add-Pendente 'b' 'projeto-b'
        (Get-ProjetosNaFila) -join ', ' | Should Be 'projeto-b, projeto-a'
    }
    It 'nao repete projeto que deixou dois resumos' {
        Reset-Fila
        Add-Pendente 'a1' 'projeto-a'
        Add-Pendente 'b1' 'projeto-b'
        Add-Pendente 'a2' 'projeto-a'
        (Get-ProjetosNaFila) -join ', ' | Should Be 'projeto-a, projeto-b'
    }
    It 'chama de sem-nome o resumo sem projeto' {
        Reset-Fila
        Add-Pendente 'x' ''
        (Get-ProjetosNaFila) -join ', ' | Should Be 'sem nome'
    }
    It 'devolve lista vazia com a fila vazia' {
        Reset-Fila
        (Get-ProjetosNaFila).Count | Should Be 0
    }
}

Describe 'Format-FalaNotificacao' {
    It 'diz qual projeto pediu permissao' {
        Format-FalaNotificacao 'Claude needs your permission to use Bash' 'voz-ao-claude' |
            Should Be 'O projeto voz-ao-claude precisa da sua permissao para continuar.'
    }
    It 'diz qual projeto esta esperando resposta' {
        Format-FalaNotificacao 'Claude is waiting for your input' 'cadeia-sequencial' |
            Should Be 'O projeto cadeia-sequencial esta esperando sua resposta.'
    }
    It 'fala na primeira pessoa quando nao sabe o projeto' {
        Format-FalaNotificacao 'Claude needs your permission to use Bash' '' |
            Should Be 'Preciso da sua permissao para continuar.'
    }
    It 'repassa mensagem desconhecida com o projeto na frente' {
        Format-FalaNotificacao 'Algo inesperado aconteceu' 'projeto-x' |
            Should Be 'No projeto projeto-x: Algo inesperado aconteceu'
    }
    It 'repassa mensagem desconhecida sem projeto' {
        Format-FalaNotificacao 'Algo inesperado aconteceu' '' |
            Should Be 'Algo inesperado aconteceu'
    }
    It 'devolve vazio para mensagem vazia' {
        Format-FalaNotificacao '' 'projeto-x' | Should BeNullOrEmpty
    }
}

Describe 'Get-CwdDoHook' {
    It 'tira o cwd do JSON que o Claude Code manda no stdin' {
        Get-CwdDoHook '{"session_id":"abc","cwd":"C:\\dev\\meu-projeto","hook_event_name":"Stop"}' | Should Be 'C:\dev\meu-projeto'
    }
    It 'devolve vazio quando o JSON nao tem cwd' {
        Get-CwdDoHook '{"session_id":"abc"}' | Should BeNullOrEmpty
    }
    It 'nao quebra com entrada que nao e JSON' {
        Get-CwdDoHook 'isso nao e json' | Should BeNullOrEmpty
    }
    It 'nao quebra com entrada vazia' {
        Get-CwdDoHook '' | Should BeNullOrEmpty
    }
}

Remove-Item $ClarisseRoot -Recurse -Force -ErrorAction SilentlyContinue

Describe 'ordem da fila quando dois resumos chegam juntos' {
    # Medido: em 200 repeticoes de "dois resumos em pasta vazia", 34% caem no
    # mesmo milissegundo (o relogio do Windows tem granularidade grosseira) e
    # 22% saem na ordem invertida, porque o desempate era o guid aleatorio.
    # Import-Entradas enfileira todas as caixas em laco, no mesmo processo:
    # com varias sessoes terminando juntas, esse e o caso normal, nao a excecao.
    #
    # Repetido varias vezes de proposito: uma unica passada acerta por sorte em
    # quatro de cada cinco tentativas e nao provaria nada.
    It 'entrega sempre o mais recente primeiro, em 40 repeticoes' {
        $invertidas = 0
        foreach ($tentativa in 1..40) {
            Reset-Fila
            Add-Pendente 'Resumo antigo.' 'projeto-a'
            Add-Pendente 'Resumo novo.'   'projeto-b'
            if ((Read-Pendente).texto -ne 'Resumo novo.') { $invertidas++ }
        }
        $invertidas | Should Be 0
    }

    It 'lista os projetos em ordem estavel na triagem, em 40 repeticoes' {
        $erradas = 0
        foreach ($tentativa in 1..40) {
            Reset-Fila
            Add-Pendente 'a' 'projeto-a'
            Add-Pendente 'b' 'projeto-b'
            if (((Get-ProjetosNaFila) -join ',') -ne 'projeto-b,projeto-a') { $erradas++ }
        }
        $erradas | Should Be 0
    }

    It 'preserva a ordem de chegada de cinco resumos seguidos' {
        $erradas = 0
        foreach ($tentativa in 1..15) {
            Reset-Fila
            1..5 | ForEach-Object { Add-Pendente "resumo $_" "projeto-$_" }
            $saida = @()
            while ($true) {
                $item = Read-Pendente
                if (-not $item) { break }
                $saida += $item.texto
            }
            if (($saida -join '|') -ne 'resumo 5|resumo 4|resumo 3|resumo 2|resumo 1') { $erradas++ }
        }
        $erradas | Should Be 0
    }
}
