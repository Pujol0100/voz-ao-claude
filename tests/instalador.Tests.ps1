# O instalador copia uma lista de arquivos escrita a mao. Um arquivo novo no
# codigo que ninguem lembra de acrescentar ali gera a pior falha possivel: a
# instalacao termina anunciando sucesso e a Clarisse fica muda, porque a peca
# que faltou so e procurada na hora de falar.

Describe 'instalador' {
    It 'copia todo arquivo de codigo que existe na pasta clarisse' {
        $origem = Join-Path $PSScriptRoot '..\clarisse'
        $codigo = @(
            Get-ChildItem $origem -File |
                Where-Object { @('.ps1', '.py') -contains $_.Extension } |
                ForEach-Object { $_.Name }
        )
        $codigo.Count | Should BeGreaterThan 0

        $instalador = [System.IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot '..\instalar.ps1'), [System.Text.Encoding]::UTF8)

        $faltando = @($codigo | Where-Object { $instalador -notmatch [regex]::Escape($_) })
        ($faltando -join ', ') | Should BeNullOrEmpty
    }
}
