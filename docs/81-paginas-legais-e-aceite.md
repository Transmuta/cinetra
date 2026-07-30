# 76 — Política de Privacidade, Termos de Uso e o aceite no cadastro

Duas páginas públicas novas (`/privacidade` e `/termos`), com a mesma linguagem visual da landing,
e o aceite dos dois documentos no `/criar-conta`.

Pedido de 2026-07-29. As três decisões de escopo foram do usuário, no início da fatia:

| Decisão | Escolha | Consequência |
| --- | --- | --- |
| Identificação do controlador | **Placeholders marcados** (`[RAZÃO SOCIAL]`, `[CNPJ]`, …) | Nada de CNPJ inventado; falta preencher antes de publicar → [D-13](50-debitos-tecnicos.md) |
| Onde o aceite fica registrado | **Só no formulário**, sem persistência | Sem migração; o aceite não é provável depois → [D-14](50-debitos-tecnicos.md) |
| Como tratar o botão do Google | **Nota, sem caixa de seleção** | Um texto só cobre os dois caminhos de cadastro |

## 1. Por que o aceite virou NOTA, e não caixa obrigatória

A pergunta inicial era com caixa (`required` + validação no BFF). O usuário virou a decisão, e a
razão é boa: **o cadastro tem dois caminhos**, e eles não se travam do mesmo jeito.

- O magic link é um `<form>`: uma caixa `required` funciona, e o BFF ainda pode reprovar quem
  burlar o HTML por `curl`.
- O Google é um `<a href="/auth/google" data-sveltekit-reload>` que **sai da página** por navegação
  completa. Caixa de seleção nenhuma trava um link sem JavaScript, e travá-lo com JavaScript daria
  uma garantia que cai junto com o script.

Uma caixa que vale em um caminho e não no outro é pior que nenhuma: dá aparência de controle onde
não há. A nota fica **depois dos dois botões** e cobre os dois por texto:

> Ao criar sua conta, por e-mail ou com o Google, você concorda com os **Termos de Uso** e a
> **Política de Privacidade**.

Só a tela que cria conta a mostra. `/entrar` não repete: repetir aviso onde ele não se aplica é a
receita para ninguém mais lê-lo.

## 2. O conteúdo é DADO, não markup

Os dois documentos moram em [`web/src/lib/legal.ts`](../web/src/lib/legal.ts), na mesma forma que o
`FAQ` de `seo.ts`: uma lista de seções, cada uma com parágrafos e listas.

Não é preciosismo. **O sumário e o corpo saem do mesmo array**, então o índice não tem como apontar
para uma âncora que o texto não tem. Índice escrito à mão ao lado de um texto de três mil palavras é
exatamente onde essa divergência nasce, e é o tipo de defeito que ninguém enxerga relendo a página.

Isso também deu testes que um `.svelte` de prosa não permitiria ([`legal.test.ts`](../web/src/lib/legal.test.ts)):
seção sem conteúdo, id repetido, HTML solto no dado, descrição fora do corte do buscador, contato
de privacidade ausente, e a preferência de escrita do projeto (**a copy não usa travessão**), que o
FAQ já cobrava e que reaparece sozinha em texto jurídico.

Um teste merece destaque:

```ts
it('os dados do controlador estão marcados como pendentes, nunca inventados', () => {
    for (const campo of [EMPRESA.razaoSocial, EMPRESA.cnpj, EMPRESA.endereco, EMPRESA.foro]) {
        expect(campo).toMatch(/^\[.+\]$/);
    }
    expect(EMPRESA.cnpj).not.toMatch(/\d/);
});
```

Ele existe para impedir que alguém "feche" o texto preenchendo um CNPJ plausível. Enquanto o
placeholder estiver lá, a pendência está **declarada** em vez de esquecida.

## 3. O texto descreve o que o sistema faz, não o que seria bonito prometer

Cada afirmação técnica foi conferida contra o código, e é isto que o documento afirma:

| Afirmação no texto | Onde ela é verdade no código |
| --- | --- |
| Isolamento por clínica aplicado **no banco** | RLS + GUC (`Api.Tenancy.SetTenantGuc`) |
| Trilha de auditoria retida por **90 dias** | `Api.Audit.retencao_dias/0` + `Api.Housekeeping.PruneTrail` |
| Notificações: 90 dias após a leitura, 365 no máximo | `Api.Housekeeping.PruneNotifications` |
| Anexo não fica em endereço público; a abertura é registrada | URL assinada (`Api.Storage.SigV4`) + trilha `:visualizou` |
| Login sem senha, sessão revogável em todos os dispositivos | magic link/Google + `log_out_everywhere` |
| Operadores nomeados: Cloudflare R2, Resend, Zernio | `api/config/runtime.exs` |
| Só cookie necessário, sem rastreador de terceiros | cookie de sessão cifrado (`_api_key`) |

**Onde o texto promete e o código ainda não entrega**, a promessa é comercial e está registrada como
tal (a landing já a fazia, [doc 57](57-seo-e-performance-da-landing.md)): a seção *Teste grátis,
planos e pagamento* dos Termos descreve um modelo de cobrança que **não existe implementado**. Sem
essa seção, porém, os Termos ficariam mudos justamente sobre o que o cliente assina.

Uma escolha de conteúdo que não é óbvia: a política **separa os dois papéis** logo na segunda
seção. Para os dados de quem usa o sistema, a Cinetra é **controladora**; para os dados dos
pacientes, quem controla é **a clínica**, e a Cinetra é **operadora**. Isso muda para quem o
paciente dirige um pedido de acesso ou exclusão, e um documento que não diz isso empurra para a
Cinetra pedidos que ela não pode atender sozinha.

## 4. O que mudou na landing (e por quê)

O topo e o rodapé saíram de dentro de [`+page.svelte`](../web/src/routes/+page.svelte) e viraram
[`SiteHeader`](../web/src/lib/components/cinetra/SiteHeader.svelte) e
[`SiteFooter`](../web/src/lib/components/cinetra/SiteFooter.svelte). As páginas legais precisam do
**mesmo** chrome, e duas cópias de uma barra de navegação divergem no dia em que alguém acrescenta
um item numa só.

Uma diferença real entre os dois usos, que virou prop:

- na landing, a navegação é **âncora pura** (`#precos`): as seções são daquela página;
- fora dela, a mesma âncora precisa voltar para a home antes de rolar (`/#precos`), senão o link
  não faz nada.

Daí `SiteHeader` receber `prefixo` (vazio na landing, `/` nas legais). O rodapé usa sempre a forma
absoluta, porque ele aparece nas duas.

O rodapé ganhou os links dos dois documentos: é o **único** ponto de entrada fixo para eles em toda
página pública.

## 5. A geometria mora em CSS, e a prova mora no e2e

O layout é sumário grudado à esquerda + prosa à direita, colapsando para uma coluna abaixo de 900px.
Duas decisões de leitura:

- a prosa para em **65ch**, não na largura da coluna: quem manda em texto longo é a medida da linha;
- no mobile o sumário **deixa de grudar**. `sticky` com 14 itens numa tela de 390px tomaria a janela
  inteira e ficaria por cima da leitura.

Nada disso é testável no Vitest (o jsdom não aplica CSS nem tem viewport), então virou
[`e2e/paginas-legais.spec.ts`](../web/e2e/paginas-legais.spec.ts): transbordo horizontal a 320px e
390px nos dois documentos, o `position` do sumário em cada largura, e a âncora que **não** esconde o
título embaixo do topo fixo (é o que o `scroll-margin-top` compra).

## 6. O achado da verificação ao vivo

A varredura axe (`e2e/a11y-audit.spec.ts`, que passou a cobrir as duas páginas novas) reprovou algo
que os 2.092 testes de unidade não tinham como ver:

```
/criar-conta · color-contrast · serious
p[data-testid="aceite"] — contraste 3,29:1 (#8C8678 sobre #F6F4EF), mínimo 4,5:1
```

A nota de aceite tinha sido escrita num cinza claro **de propósito**, para não competir com os
botões. O efeito é o oposto do pretendido: uma nota legal que a pessoa não consegue ler não vale
como aviso. Corrigido para `#736E63` (4,6:1), o mesmo cinza do subtítulo do card, com o tamanho
subindo de 12,5px para 13px.

O mesmo problema aparecia no numerador do sumário (`#a8a294`, ~2,6:1). Lá a hierarquia passou a vir
do **tamanho** (11px mono contra 14px), não de um cinza mais claro.

Depois das duas correções: **0 violações** nas cinco páginas públicas.

## 7. Estado

| Gate | Resultado |
| --- | --- |
| `npm run check` | 0 erros, 0 avisos |
| `npm run coverage` | 179 arquivos, **2.092 testes**, 92,1% stmts / 77,2% branches (pisos: 80/75) |
| `npx playwright test paginas-legais` | 10 passaram |
| `npx playwright test a11y-audit` | 0 violações |

Verificado ao vivo no Chromium: as duas páginas, as âncoras do sumário, o rodapé e a nota do
cadastro.

**Não commitado.** As pendências de conteúdo estão em
[`50-debitos-tecnicos.md`](50-debitos-tecnicos.md), itens **D-13** e **D-14**.
