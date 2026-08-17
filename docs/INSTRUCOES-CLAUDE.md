# Clarisse — resumo falado

`<required>` Ao terminar **cada** resposta, escreva o resumo falado em
`{{CLARISSE_DIR}}\fala.txt` (UTF-8, sobrescrevendo).
Um hook guarda esse texto na fila e emite um bipe. O usuario aperta `Ctrl+Alt+L`
para ouvir quando quiser. Se voce nao escrever, nada fica na fila. `</required>`

## A regra que importa: diga o conteudo, nao o aviso

O resumo e lido sob comando, entao ele pode e deve carregar **substancia**.
Ninguem aperta o atalho para ouvir "terminei, da uma olhada".

`<required>` E **proibido** anunciar algo sem dizer o que e. Toda vez que o
resumo mencionar um problema, uma decisao, uma pendencia, um resultado ou uma
diferenca, o **conteudo** tem que vir na mesma frase. `</required>`

| Nao escreva | Escreva |
|---|---|
| "Encontrei um problema." | "O calculo de ferias esta somando o adicional noturno duas vezes." |
| "Preciso da sua decisao." | "Preciso decidir se o desconto entra antes ou depois do imposto." |
| "Ficou uma pendencia." | "Falta o CNPJ do fornecedor para fechar o cadastro." |
| "Os testes rodaram." | "Rodei os quarenta testes: trinta e oito passaram e dois falharam na conversao de data." |
| "Analisei a planilha." | "A planilha tem trezentos e doze lancamentos e quatro estao sem centro de custo." |
| "Da uma olhada na tela." | (nunca; diga o achado) |

## Conteudo, nesta ordem

1. **O que foi feito e o que resultou.** Depois de rodar qualquer aplicacao,
   script ou teste, diga o que rodou e como terminou — com o numero.
2. **O achado ou a conclusao.** O que voce descobriu, nao a narrativa de como
   descobriu. Se comparou coisas, diga a diferenca. Se avaliou, diga o veredito.
3. **O que falta ou o que voce precisa do usuario**, dito por extenso. Se nao
   houver nada, diga que esta concluido.
4. **Numeros, valores e datas.** Repita todo valor em reais, prazo, data e
   quantidade que apareceu na resposta, escritos por extenso para a voz sair
   certa: "doze mil, quatrocentos e cinquenta reais", "trinta de setembro de
   dois mil e vinte e seis", "trinta e sete por cento".

**Avisos:** antes de qualquer acao irreversivel — apagar, sobrescrever, enviar,
publicar, alterar dados de producao — escreva o aviso em `fala.txt` **antes** de
executar e pare para confirmar.

## Estilo do texto falado

- Portugues falado, frases curtas. Sem markdown, sem bullets, sem tabelas.
- Nunca leia caminho de arquivo, comando, bloco de codigo, URL ou hash. Diga
  "o script principal", "o arquivo de configuracao", "o teste de conversao".
- Nunca escreva o resumo em ingles.
- 4 a 8 frases. Limite pratico de 1500 caracteres; o script corta em 1800.
- A tela tem o detalhe e o codigo. O audio tem o resultado, o achado e o numero.

**Privacidade:** o texto do resumo e enviado ao servico de sintese da Microsoft
para virar audio. Nao coloque no resumo falado credencial, dado pessoal de
terceiros, nome de cliente ou valor exato de contrato. Prefira "o valor
combinado" a repetir a cifra quando o assunto for sensivel.

Se `enabled` estiver `false` no config, o hook ignora o arquivo — continue
escrevendo normalmente.
