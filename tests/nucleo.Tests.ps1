# Testes do nucleo da Clarisse. Rodar com: Invoke-Pester .\tests
# Escritos na sintaxe do Pester 3.x ("Should Be"), que e a versao que vem no Windows.

$ClarisseRoot = Join-Path $env:TEMP ("clarisse-testes-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $ClarisseRoot | Out-Null

. (Join-Path $PSScriptRoot '..\clarisse\nucleo.ps1')

Describe 'ConvertTo-Falavel' {
    It 'remove bloco de codigo, marcacao e espaco repetido' {
        $bruto = "## Titulo`n**forte** e ``codigo``.`n" + '```' + "`nrm -rf /`n" + '```' + "`n- item"
        $r = ConvertTo-Falavel $bruto 500
        $r | Should Not Match 'rm -rf'
        $r | Should Not Match '\*\*'
        $r | Should Not Match '##'
        $r | Should Match 'Titulo'
    }
    It 'corta no fim de frase quando passa do limite' {
        $r = ConvertTo-Falavel ('Primeira frase curta. ' + ('palavra ' * 200)) 60
        $r.Length | Should BeLessThan 70
        $r | Should Match '\.\.\.$'
    }
    It 'devolve vazio para entrada em branco' {
        ConvertTo-Falavel '   ' 500 | Should BeNullOrEmpty
    }
}

Describe 'controle de reproducao' {
    It 'devolve tocar quando nao ha arquivo de controle' {
        Remove-Item $ControlePath -Force -ErrorAction SilentlyContinue
        Get-Controle | Should Be 'tocar'
    }
    It 'guarda e devolve o estado gravado' {
        Set-Controle 'pausado'
        Get-Controle | Should Be 'pausado'
        Set-Controle 'cancelar'
        Get-Controle | Should Be 'cancelar'
    }
    It 'ignora valor invalido e cai em tocar' {
        [System.IO.File]::WriteAllText($ControlePath, 'lixo')
        Get-Controle | Should Be 'tocar'
    }
    It 'alterna tocar para pausado e de volta' {
        Set-Controle 'tocar'
        Switch-Pausa | Should Be 'pausado'
        Get-Controle | Should Be 'pausado'
        Switch-Pausa | Should Be 'tocar'
        Get-Controle | Should Be 'tocar'
    }
}

# A fila de resumos pendentes tem testes proprios em fila.Tests.ps1.

Describe 'ConvertTo-CodigoAtalho' {
    It 'traduz Ctrl+Alt+L' {
        $r = ConvertTo-CodigoAtalho 'Ctrl+Alt+L'
        $r.vk  | Should Be 76
        $r.mod | Should Be (2 -bor 1 -bor 0x4000)
    }
    It 'aceita nome por extenso, caixa baixa e tecla de seta' {
        $r = ConvertTo-CodigoAtalho 'control+shift+up'
        $r.vk  | Should Be 38
        $r.mod | Should Be (2 -bor 4 -bor 0x4000)
    }
    It 'aceita a tecla Windows' {
        (ConvertTo-CodigoAtalho 'Win+Alt+X').mod | Should Be (8 -bor 1 -bor 0x4000)
    }
    It 'devolve nulo sem modificador' {
        ConvertTo-CodigoAtalho 'L' | Should BeNullOrEmpty
    }
    It 'devolve nulo com tecla inexistente' {
        ConvertTo-CodigoAtalho 'Ctrl+Alt+Batata' | Should BeNullOrEmpty
    }
    It 'devolve nulo com duas teclas normais' {
        ConvertTo-CodigoAtalho 'Ctrl+L+X' | Should BeNullOrEmpty
    }
    It 'devolve nulo para entrada vazia' {
        ConvertTo-CodigoAtalho '' | Should BeNullOrEmpty
    }
}

Describe 'Get-Config' {
    It 'usa 1800 caracteres como padrao quando nao ha config' {
        Remove-Item $ConfigPath -Force -ErrorAction SilentlyContinue
        (Get-Config).maxChars | Should Be 1800
    }
    It 'traz os tres atalhos no padrao' {
        Remove-Item $ConfigPath -Force -ErrorAction SilentlyContinue
        $a = (Get-Config).atalhos
        $a.ler      | Should Be 'Ctrl+Alt+L'
        $a.pausar   | Should Be 'Ctrl+Alt+P'
        $a.cancelar | Should Be 'Ctrl+Alt+X'
    }
}

Describe 'Get-RateMaisLento' {
    It 'tira 25 pontos percentuais' { Get-RateMaisLento '+12%' | Should Be '-13%' }
    It 'respeita o piso de -40%'    { Get-RateMaisLento '-30%' | Should Be '-40%' }
}

Describe 'historico' {
    It 'guarda no maximo cinco falas, da mais nova para a mais velha' {
        Remove-Item $HistPath -Force -ErrorAction SilentlyContinue
        1..7 | ForEach-Object { Add-Historico "fala $_" }
        $itens = Get-ItensHistorico
        $itens.Count | Should Be 5
        $itens[0]    | Should Be 'fala 7'
        $itens[4]    | Should Be 'fala 3'
    }
    It 'ignora texto em branco' {
        Remove-Item $HistPath -Force -ErrorAction SilentlyContinue
        Add-Historico '   '
        (Get-ItensHistorico).Count | Should Be 0
    }
}

Remove-Item $ClarisseRoot -Recurse -Force -ErrorAction SilentlyContinue
