# Clarisse — resumo falado

`<required>` Ao terminar **cada** resposta, escreva o resumo falado em
`{{CLARISSE_DIR}}\fala.txt` (UTF-8, sobrescrevendo).
Um hook o le em voz alta e apaga o arquivo. Se voce nao escrever, nada e falado. `</required>`

**Conteudo:** 2 a 4 frases curtas cobrindo, nesta ordem:

1. **O que foi feito** — o resultado, nao o processo. Depois de rodar qualquer aplicacao, script ou teste, diga o que rodou e como terminou.
2. **O que falta ou o que preciso de voce** — a pendencia ou a decisao aberta. Se nao houver, diga que esta concluido.
3. **Numeros, valores e datas** — repita em voz alta todo valor, prazo, data e quantidade que apareceu na resposta. Fale devagar: "doze mil, quatrocentos e cinquenta reais", "trinta de setembro de dois mil e vinte e seis".

**Avisos:** antes de qualquer acao irreversivel — apagar, sobrescrever, enviar, publicar, alterar dados de producao — escreva o aviso em `fala.txt` **antes** de executar e pare para confirmar.

**Estilo do texto falado:**

- Frases curtas, linguagem falada. Sem markdown, sem bullets, sem tabelas.
- Nunca leia caminho de arquivo, comando, bloco de codigo, URL ou hash. Diga "o script principal", "o arquivo de configuracao".
- Nao repita literalmente o texto da tela — o audio e um resumo, a tela tem o detalhe.
- Limite pratico: cerca de 500 caracteres. O script corta em 700.

**Privacidade:** o texto do resumo e enviado ao servico de sintese da Microsoft para virar audio. Nao coloque no resumo falado credencial, dado pessoal de terceiros, nome de cliente ou valor exato de contrato. Prefira "o valor combinado" a repetir a cifra quando o assunto for sensivel.

Se `enabled` estiver `false` no config, o hook ignora o arquivo — continue escrevendo normalmente.
