# 104 — A tela do paciente: a marca que faltava, e a sessão que não existia mais

**2026-08-04.** A `/confirmar/[token]` (doc 52 §5) é a **única superfície do produto que um
estranho vê**: quem abre não tem login, não conhece a Cinetra e chegou ali por uma mensagem da
clínica. Ela funcionava — uma pergunta, dois botões, o `enhance` por botão que o doc 60 já tinha
acertado. O que ela não fazia era **parecer a continuação do e-mail que a trouxe**, e o que ela
dizia nem sempre continuava verdadeiro.

Três achados, e o terceiro não é estético.

---

## 1. Duas marcas a um clique de distância

O e-mail do paciente (`Api.EmailLayout`) é papel quente: fundo `#EFEDE7`, cartão `#FBFAF6`, um
**bloco navy com o nome da clínica** em 28px, régua sálvia de 52×3 abaixo dele, telefone, e a
Cinetra só no rodapé — porque quem fala com o paciente é a clínica, e nós somos quem entrega.

A tela usava o **design system do app interno**: `bg-surface` branco-azulado, `rounded-cartao`,
sem logo, sem navy, sem régua. E, por não ter cookie de tema, ela seguia o `prefers-color-scheme`
do aparelho. Medido:

```
$ curl -s localhost:5173/confirmar/<token> | head -2
<html lang="pt-BR">          # sem data-theme: quem decide é o prefers-color-scheme
```

`hooks.server.ts` só estampa `data-theme` a partir do cookie `mv-theme`, e **o paciente nunca tem
esse cookie**. Com `@media (prefers-color-scheme: dark)` em `app.css:291`, quem lê no escuro recebia
um e-mail creme e abria uma página quase preta. Num link que chega por WhatsApp, isso não é
inconsistência de gosto: é o sinal de que a página é de outra pessoa.

**A decisão já existia e não tinha sido aplicada aqui.** O `AuthCard` (entrar/criar-conta/comecar)
crava `data-theme="light"` + `color-scheme:light` no próprio nó desde 2026-07-30, com a justificativa
escrita: *"papel/navy é pigmento da marca, não superfície de app"*. A `/confirmar` ficou de fora.

## 2. O que a pessoa veio decidir não estava em destaque

O maior elemento da tela era `Olá, Ana!`. A data aparecia como **`05/08/2026`** — número, sem dia da
semana, dentro de um parágrafo — e o telefone da clínica **não aparecia**, embora estivesse no
`vars` da própria mensagem (medido no banco: `{"telefone": "(61) 99946-6274", ...}`) e no corpo de
todo template (*"Ligue para {{5}}"*).

Quem abre esse link está no ônibus decidindo se sai de casa. O que responde isso é **quando** —
e, antes disso, "amanhã".

## 3. A sessão congelada: o achado que não é de UI

O resumo saía inteiro do `message.vars`, que é **congelado no envio** (é dele que a timeline da
recepção é desenhada, e tem de continuar dizendo o que a mensagem disse). Só que o link vale **30
dias**, e nesse intervalo a sessão muda. Medido na base de dev, na mensagem que eu abri para tirar
o screenshot:

| o que a mensagem congelou | o que a sessão é hoje | status |
| --- | --- | --- |
| 05/08/2026 08:30 | 05/08/2026 **10:30** | **cancelada** |

A tela dizia *"Sua sessão está marcada para 05/08/2026 às 08:30"* e oferecia **Confirmar presença**
— para uma sessão que a clínica já tinha cancelado, no horário errado.

---

## 4. A régua que decide o que a API devolve

O `PatientReplyController` tinha um parágrafo chamado *"por que devolve tão pouco"*, e ele estava
certo: o link se encaminha. Mas "pouco" não é critério — dava para argumentar qualquer coisa dos
dois lados. A régua agora está escrita:

> **A página não conta nada que a mensagem já não tenha contado.**

O que ela decide, na prática:

- **entra o telefone da clínica** (`clinica_telefone`), porque ele está no corpo de todo template.
  Mostrá-lo não amplia em nada o que um encaminhamento revela;
- **fica de fora profissional, endereço e tipo de atendimento** — nenhum aparece em template
  nenhum. Se um dia aparecerem, a régua os deixa entrar sozinha;
- **`telefone` cru continua sendo o do paciente e continua fora.** O nome novo (`clinica_telefone`)
  é o que mantém o teste `refute Map.has_key?(body, "telefone")` significando o que ele sempre
  significou;
- **`inicio`, `fim`, `timezone` e `ativa` são a exceção** — e não contam dado novo: contam o
  **mesmo** dado atualizado. Sem eles a página só sabe repetir a string congelada.

## 5. A armadilha de RLS que estava no caminho (e o que a mediu)

Ler a presença de dentro do `with_message/2` **não levantaria erro**: `with_message` seta
`cinetra.message_id`, que é a GUC que a policy de `messages` aceita — e `attendances` tem RLS por
`cinetra.clinic_id`. A leitura voltaria **vazia**, calada, e a tela concluiria "sessão cancelada"
para **toda sessão viva do produto**, com a suíte verde (o sandbox conecta como `postgres`).

É a regra 3 de [`.claude/rules/migrations.md`](../.claude/rules/migrations.md), e o instrumento é o
`psql` sob o role restrito, sempre com o controle positivo junto:

```
cinetra_app, SEM GUC : 0 presenças     ← RLS fechando
cinetra_app, COM GUC : 1 presença      ← controle positivo
postgres,   mesma clínica : 1 presença ← bate
```

Por isso `contexto/1` abre um `with_clinic/2` **depois** de ler a mensagem: o `clinic_id` só é
conhecido a partir dela. São duas transações numa rota pública, de baixo volume e sob rate limit —
e é o preço de a leitura não mentir.

## 6. O que a tela faz agora

| Estado | O que ela mostra |
| --- | --- |
| perguntando | clínica no topo (navy + régua + telefone discável), `10:00` em 34px, `segunda-feira, 10 de agosto`, selo `amanhã` quando cabe, dois botões a 14px de distância |
| confirmou | caixa **verde** de desfecho + **adicionar à agenda** (`.ics`) + "mudar minha resposta" |
| quer remarcar | caixa **azul** de espera (não é desfecho: depende de a clínica ligar) + **ligar para a clínica** + "mudar minha resposta" |
| sessão cancelada | "Esta sessão foi cancelada", sem botão de confirmar, com o telefone |
| sessão já passada | "Essa sessão já passou", idem |
| link inválido/vencido | mesma moldura, assinada pela Cinetra (não há clínica a anunciar) |

Quatro decisões dentro disso:

1. **O `.ics` é uma rota, não um `data:` nem um Blob.** O Chrome bloqueia navegação de topo para
   `data:` e o iOS não baixa Blob de forma confiável — as duas alternativas falham exatamente no
   aparelho em que esta tela mais é aberta. O `UID` é um **digest do token**, não o token: o arquivo
   acaba em calendário compartilhado com a família, e um `UID` estável ainda faz o app **atualizar**
   o evento quando a sessão for remarcada, em vez de criar um segundo.
2. **"Mudar minha resposta" some por padrão e é preciso pedir.** Deixar os dois botões depois de
   responder convida ao segundo toque sem saber se o primeiro valeu (é o motivo pelo qual eles
   sumiam); não ter saída nenhuma faz quem tocou errado ligar para a clínica. O domínio já
   suportava a troca — `confirmou → quer_remarcar` avisa a recepção de novo, e há teste para isso
   desde o doc 65.
3. **Dois tons, e a diferença não é decorativa.** Pintar "preciso remarcar" de verde dizia
   "resolvido" para quem ainda não tem horário nenhum.
4. **14px entre os botões, não 8px.** São respostas opostas, num celular, muitas vezes em rede
   ruim — o toque que erra por um dedo mandava o contrário do que a pessoa quis.

## 7. Arquivo a arquivo

**Backend**

| Arquivo | O quê |
| --- | --- |
| [`patient_reply_controller.ex`](../api/lib/api_web/controllers/patient_reply_controller.ex) | `resumo/1` ganha `clinica_telefone`, `inicio`, `fim`, `timezone`, `ativa`; `contexto/1` lê presença/bloco/clínica sob `with_clinic`; a régua no moduledoc |
| [`scheduling.ex`](../api/lib/api/scheduling.ex) | `define :get_attendance, action: :read, get_by: [:id]` |
| [`patient_reply_controller_test.exs`](../api/test/api_web/controllers/patient_reply_controller_test.exs) | +6 testes: telefone da clínica, instante e fuso, fim da sessão, sessão viva, cancelada, remarcada |

**Web**

| Arquivo | O quê |
| --- | --- |
| [`cinetra/CartaoPaciente.svelte`](../web/src/lib/components/cinetra/CartaoPaciente.svelte) | a moldura: `.cn-root` claro, topo navy com a clínica, régua sálvia, telefone `tel:`, assinatura |
| [`styles/cinetra.css`](../web/src/lib/styles/cinetra.css) | seção `.cn-paciente-*` — hex de marca em CSS, onde ganham media query e `:focus-visible` |
| [`data-hora.ts`](../web/src/lib/data-hora.ts) | `quandoParaPaciente/3` — a quarta forma de dizer "quando", a única que não fala com a recepção |
| [`server/ics.ts`](../web/src/lib/server/ics.ts) | `eventoIcs/1` e `uidDeSessao/1` (RFC 5545: CRLF, escape, dobra em 75 **octetos** sem partir multibyte) |
| [`confirmar/[token]/resposta.ts`](../web/src/routes/confirmar/[token]/resposta.ts) | a chamada à API num lugar só — o `.ics` é o segundo consumidor, e o IP do paciente não pode divergir entre eles |
| [`confirmar/[token]/sessao.ics/+server.ts`](../web/src/routes/confirmar/[token]/sessao.ics/+server.ts) | serve o evento; 404 sem instante ou com sessão cancelada |
| [`confirmar/[token]/+page.svelte`](../web/src/routes/confirmar/[token]/+page.svelte) | a tela |
| [`e2e/tema-auth-claro.spec.ts`](../web/e2e/tema-auth-claro.spec.ts) | `/confirmar/token-invalido` entra na varredura de tema |

Testes novos: 6 no backend, 79 no web nos arquivos tocados (`ics`, `data-hora`, `resposta`,
`sessao.ics`, `CartaoPaciente`, a página).

## 8. Gates

| Gate | Resultado |
| --- | --- |
| `mix coveralls` | 2047 testes, **90,5%** (piso 80). 1 falha **pré-existente e alheia** — ver §9 |
| `mix test --only rls` (como `cinetra_app`) | 0 falhas |
| `mix format --check-formatted` + `compile --warnings-as-errors` | limpo |
| `npm run check` | 0 erros |
| `npm run coverage` | 2612 testes, **93,1%** linhas / 79,7% branches (piso 80/75) |
| e2e | **não rodou aqui**: o container `web` não tem os browsers do Playwright instalados (`npx playwright install`). Os 4 cenários do arquivo falham por isso, inclusive os 2 que já existiam |

O tema foi provado sem o e2e, por dois fatos medidos mais um invariante já guardado: com
`mv-theme=dark`, o `<html>` sai `data-theme="dark"` **e** o nó do cartão sai
`data-theme="light" style="color-scheme:light"`; que os tokens claros valem para um
`[data-theme='light']` que não é o `:root` é o que `styles/tema-escopo.test.ts` guarda desde a
auth.

## 9. Dois achados alheios a esta fatia, que apareceram rodando os gates

Nenhum dos dois é consequência do que mudou aqui; ficam registrados porque foram medidos e são
mais graves que a fatia.

1. **`cinetra-prod-age.key` está na raiz do repositório** (189 bytes, `-rw-------`, gitignorada).
   É o teste `test/api/segredo_no_working_tree_test.exs` — desta branch, ainda não commitado — que
   a acusa, e o texto dele é o alerta: essa chave **decifra todo backup**, e tanto o `backup.sh`
   quanto o `restore.sh` afirmam por escrito que ela vive fora do servidor. É a única falha da
   suíte do backend.
2. **`web/src/lib/components/agenda/.env`** (1,2 KB, "Segredos locais de desenvolvimento",
   gitignorada) mora **dentro da árvore de fontes**. Hoje o sintoma é cosmético — o v8 tenta
   parseá-lo para cobertura e loga `PARSE_ERROR` —, mas segredo dentro de `src/` é uma cópia a um
   `COPY` de distância de uma imagem.

## 10. O que ficou de fora

- **`/descadastrar/[token]` continua com a cara antiga.** É a irmã desta tela (mesmo público, mesmo
  tipo de link) e o `CartaoPaciente` já serve a ela sem mudança nenhuma — é trocar a moldura e as
  classes. Ficou de fora porque o pedido era sobre a confirmação; enquanto não for feito, as duas
  telas de paciente falam línguas visuais diferentes.
- **O POST não recusa resposta em sessão cancelada.** O `show` avisa (`ativa: false`) e a tela não
  oferece os botões, mas uma aba velha ainda consegue postar. Deixado assim de propósito: gravar
  "quero remarcar" numa sessão cancelada é justamente o que a recepção precisa saber, e recusar
  mudaria a semântica de uma rota pública por um ganho hipotético.
- **Sem `LOCATION` no `.ics`.** Endereço não está em template nenhum — é a régua do §4 valendo.
