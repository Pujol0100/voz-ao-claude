# Testes da coordenacao entre quem sintetiza (script Python) e quem toca (aqui).
#
# O risco central: um mp3 ainda sendo gravado abre no player com duracao errada
# e a fala corta no meio. Por isso o sinal de "pode tocar" nao e a existencia do
# mp3, e sim um arquivo-sentinela que o Python escreve DEPOIS de fechar o mp3.

$ClarisseRoot = Join-Path $env:TEMP ("clarisse-prog-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $ClarisseRoot | Out-Null

. (Join-Path $PSScriptRoot '..\clarisse\nucleo.ps1')

function New-PastaSegmentos {
    $p = Join-Path $ClarisseRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $p | Out-Null
    return $p
}

function Write-Falso([string]$pasta, [string]$nome, [string]$conteudo = 'x') {
    [System.IO.File]::WriteAllText((Join-Path $pasta $nome), $conteudo)
}

Describe 'Get-CaminhoSegmento' {
    It 'numera com tres digitos para os arquivos ficarem em ordem' {
        (Split-Path -Leaf (Get-CaminhoSegmento 'C:\x' 0))  | Should Be 'seg000.mp3'
        (Split-Path -Leaf (Get-CaminhoSegmento 'C:\x' 7))  | Should Be 'seg007.mp3'
        (Split-Path -Leaf (Get-CaminhoSegmento 'C:\x' 12)) | Should Be 'seg012.mp3'
    }
}

Describe 'Test-SegmentoPronto' {
    It 'e falso quando nao existe nada na pasta' {
        Test-SegmentoPronto (New-PastaSegmentos) 0 | Should Be $false
    }

    It 'e falso quando o mp3 existe mas a sentinela ainda nao' {
        # O caso que corta a fala no meio: o Python ainda esta gravando.
        $p = New-PastaSegmentos
        Write-Falso $p 'seg000.mp3'
        Test-SegmentoPronto $p 0 | Should Be $false
    }

    It 'e verdadeiro quando a sentinela acompanha o mp3' {
        $p = New-PastaSegmentos
        Write-Falso $p 'seg000.mp3'
        Write-Falso $p 'seg000.ok' ''
        Test-SegmentoPronto $p 0 | Should Be $true
    }

    It 'olha o segmento pedido, nao qualquer um' {
        $p = New-PastaSegmentos
        Write-Falso $p 'seg000.mp3'
        Write-Falso $p 'seg000.ok' ''
        Test-SegmentoPronto $p 1 | Should Be $false
    }
}

Describe 'Wait-SegmentoPronto' {
    It 'devolve pronto quando a sentinela ja esta la' {
        $p = New-PastaSegmentos
        Write-Falso $p 'seg000.mp3'
        Write-Falso $p 'seg000.ok' ''
        Wait-SegmentoPronto $p 0 5 | Should Be 'pronto'
    }

    It 'devolve erro quando o Python reporta falha' {
        $p = New-PastaSegmentos
        Write-Falso $p 'erro.txt' 'sem rede'
        Wait-SegmentoPronto $p 0 5 | Should Be 'erro'
    }

    It 'devolve timeout quando nada aparece no prazo' {
        $p = New-PastaSegmentos
        Wait-SegmentoPronto $p 0 1 | Should Be 'timeout'
    }

    It 'prefere tocar o segmento pronto mesmo havendo erro depois dele' {
        # O erro pode ser de um segmento posterior: o que ja esta pronto vale.
        $p = New-PastaSegmentos
        Write-Falso $p 'seg000.mp3'
        Write-Falso $p 'seg000.ok' ''
        Write-Falso $p 'erro.txt' 'falhou no seg003'
        Wait-SegmentoPronto $p 0 5 | Should Be 'pronto'
    }

    It 'desiste na hora quando o usuario cancela a fala' {
        # Sem isso, cancelar durante a espera ficaria preso ate o timeout.
        $p = New-PastaSegmentos
        Set-Controle 'cancelar'
        $r = Wait-SegmentoPronto $p 0 30
        Set-Controle 'tocar'
        $r | Should Be 'cancelado'
    }
}
