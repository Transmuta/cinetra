# 73 — Sentry: o que ele faz, o que já temos, e a decisão

> Análise de decisão, 2026-07-28. Responde "dá para trazer o Sentry, e faz sentido?".
>
> **A resposta curta: não o Sentry, mas duas das seis coisas que ele faz estão faltando — e as
> duas se resolvem sem ele, por muito menos.**

---

## 0. A decisão que já existia

Isto não é terreno virgem. [`hooks.client.ts`](../web/src/hooks.client.ts) tem uma seção chamada
*"Para o nosso próprio backend, não para um SaaS"*, e o [doc 05 §1.2](05-observabilidade-e-producao.md)
recusa RUM com um argumento específico: **script de terceiro na tela é o caminho mais curto para
vazar identificador de paciente** (ADR-007).

O substituto foi construído: `hooks.client.ts` + `window.onerror` + `unhandledrejection` →
[`report.ts`](../web/src/lib/report.ts) → `POST /api/client-error` → stdout do BFF → Loki. Mesma
retenção, mesma jurisdição, mesma disciplina de redação.

Este documento **não** existe para repetir essa decisão. Existe para checar se ela ainda se
sustenta agora que o pipeline está de pé — e para nomear o que ficou faltando, que não é pouco.

---

## 1. O que o Sentry faz, item a item

Seis capacidades distintas. Tratá-lo como uma coisa só é o erro que faz a comparação dar errado.

| # | Capacidade | O que temos hoje |
|---|---|---|
| 1 | Captura automática de exceção (browser + servidor) | **Temos.** Três caminhos no browser, `handleError` no BFF, `Logger.*` no domínio |
| 2 | **Stack trace desminificado** (source maps) | **Não temos** — ver §2 |
| 3 | **Agrupamento** (isto é 1 bug ou 900 ocorrências? quantos usuários?) | **Não temos** — ver §3 |
| 4 | Detecção de regressão por release ("isto é novo na v1.2.3") | Não temos |
| 5 | Breadcrumbs, estado de formulário, session replay | **Recusado de propósito** — é PII |
| 6 | Performance / tracing distribuído | Adiado pelo [doc 62 §12](62-plano-de-logs.md); o `request_id` cobre o essencial (doc 72) |

Os itens 1, 5 e 6 estão resolvidos ou decididos. **A discussão real é sobre 2 e 3** — e o 4, que
vem de graça junto do 3.

---

## 2. Lacuna medida: o stack de produção é ilegível

`sourcemap` não está declarado em [`vite.config.ts`](../web/vite.config.ts) nem em
`svelte.config.js`. O default do Vite em build é `false`. Consequência concreta: o campo `stack`
que chega ao Loki em produção tem esta forma:

```
at Ki (/_app/immutable/chunks/D3kf9s.js:1:4821)
```

Nome de função de uma letra, arquivo com hash, tudo na linha 1. **A captura funciona e o
diagnóstico não.** Isso torna o item mais caro do pipeline de browser — os quatro guardas do
endpoint, a sanitização em duas camadas, o teto por aba — um investimento cujo produto final não
responde a pergunta "onde quebrou".

Em dev não aparece porque o Vite serve fonte não-minificado. É um defeito que **só existe em
produção**, que é onde ele importa.

Vale registrar que isto é uma lacuna do nosso build, não uma vantagem do Sentry: o que o Sentry
faz é receber o upload dos maps e aplicar a tradução por você. Os maps precisam existir de
qualquer forma.

---

## 3. Lacuna medida: não há agrupamento

[`report.ts`](../web/src/lib/report.ts) deduplica **por aba** (`vistos`, teto de 10 por sessão), e
o endpoint limita **por IP** (20/min). Os dois são controles de volume, e bons.

Nenhum dos dois agrupa. No Loki, cem usuários batendo no mesmo bug viram cem linhas soltas, e não
existe consulta que responda:

- é **um** bug com 100 ocorrências ou 100 bugs distintos?
- **quantos usuários** foram afetados?
- isto é **novo** ou já acontecia semana passada?

A terceira é a que dói mais na prática: sem "primeira vez visto", não há como distinguir regressão
de ruído de fundo, e é a regressão que exige agir hoje.

---

## 4. As três formas de fechar isso

### Opção A — Sentry SaaS

**Contra, e é eliminatório:** coloca script de terceiro na página e manda o dado para fora do país.
Contradiz frontalmente o doc 05 §1.2 e o ADR-007, e a arquitetura foi escolhida para rodar **dentro
do Brasil** (doc 59, VM em Vinhedo). Some-se que a CSP é fixada em build com guarda de boot
([`hooks.server.ts`](../web/src/hooks.server.ts)), então liberar `connect-src` para o Sentry é
mudança deliberada de postura de segurança, não configuração.

Há ainda o problema silencioso: o SDK do Sentry captura por padrão muito mais do que se pede
(corpo de request, breadcrumbs, variáveis locais no servidor). Toda a disciplina de redação das
três camadas do doc 05 §2.4 teria de ser reconstruída dentro do pipeline dele — e o que escapasse
já teria saído da máquina.

### Opção B — Sentry self-hosted

Resolve jurisdição e script de terceiro (dá para enviar do BFF, sem SDK no browser).

**Contra:** o self-hosted oficial é pesado — Kafka, ClickHouse, Snuba, Relay, Redis, Postgres e
workers. A documentação do projeto pede na ordem de **16 GB de RAM** só para ele. Confrontando com
o orçamento medido no [doc 62 §3.2](62-plano-de-logs.md):

| | Memória |
|---|---|
| VM inteira | 24 GB |
| Observabilidade hoje (Loki + Grafana + Alloy) | teto 2,2 GB, **uso real ~750 MB** |
| Postgres + dois ambientes da app + pico do build do release | o resto |
| **Sentry self-hosted** | **~16 GB** |

Não cabe. E mesmo que coubesse, ele passaria a ser o maior componente da máquina — a ferramenta de
observabilidade custando mais que o produto observado, que é exatamente o erro que a §3.1 do doc 62
já corrigiu uma vez ao reverter a segunda VM.

*(Os 16 GB são o mínimo documentado pelo projeto; confirmar contra a versão atual antes de usar
este número para qualquer coisa além de descartar a opção.)*

### Opção C — fechar as duas lacunas sem Sentry

**2 (stack legível):** ligar `build.sourcemap: 'hidden'` no Vite. O `'hidden'` gera os `.map` **sem**
o comentário `//# sourceMappingURL` no bundle — ou seja, o browser não os busca e eles não ficam
públicos. Ficam como artefato de build, e a tradução do stack é feita na investigação, offline.
Custo: uma linha, mais guardar os maps por release.

**3 (agrupamento):** acrescentar um campo `fingerprint` ao evento — hash de `origem` + mensagem
normalizada + primeiro frame do stack. Com ele no JSON, o Loki responde tudo:

```logql
topk(10, sum by (fingerprint) (count_over_time({env="prod"} |= "erro no browser" | json [24h])))
```

E "é novo?" vira uma comparação de janela, que o Grafana já faz. Custo: ~10 linhas em `report.ts`,
espelhadas no endpoint (que não pode confiar no cliente — mesma regra dos outros quatro guardas).

**O que a opção C não dá:** fluxo de triagem (atribuir, resolver, silenciar), detecção de regressão
por release automática, e a interface de "issue" que o Sentry tem. Isso é real e não vale fingir
que não é — só não é o gargalo hoje, com uma equipe pequena e um piloto.

### Opção D, se um dia a C não bastar — GlitchTip

Compatível com a API do Sentry, muito mais leve (Django + Postgres + Redis; sem Kafka nem
ClickHouse). E como fala o protocolo do Sentry por HTTP, **o BFF pode postar nele** sem SDK no
browser — o que preserva o invariante do ADR-007. É a saída natural se algum dia a triagem virar
o gargalo.

**Custo verificado (2026-07-28, documentação oficial):** **512 MB recomendado, 256 MB no mínimo**
com o `start-all-in-one.sh` (removendo worker/beat, e sem Valkey). Para comparação, o Grafana desta
mesma VM usa ~340 MB. Ou seja: **o GlitchTip é mais barato que qualquer painel que já rodamos** —
duas ordens de grandeza abaixo do Sentry self-hosted (~16 GB) que abriu este documento.

Isso reordena a decisão. O argumento contra o Sentry era jurisdição, script de terceiro **e** peso;
o GlitchTip não tem nenhum dos três. O que sobra é a pergunta menor — *já precisamos de fluxo de
triagem?* — e não uma restrição de arquitetura.

### Opção E — Grafana Faro (a resposta nativa do ecossistema)

O Alloy que já rodamos tem um componente `faro.receiver`: o Faro Web SDK no browser envia para o
**nosso próprio** Alloy, que encaminha ao Loki. Inclui upload de source map, então o stack sai
desminificado sem ferramenta externa.

**Não é descartável pelo ADR-007** — o dado não sai para terceiro, e o script é servido da nossa
origem. Mas há um custo específico: o Faro é **auto-instrumentado** (captura URL, clique, web
vitals, console), e URL do nosso app carrega `patient_id`. Adotá-lo significa filtrar *depois*
aquilo que hoje é allowlist *por construção* no [`report.ts`](../web/src/lib/report.ts) e no
endpoint. A troca é: ganha-se web vitals e source map prontos, perde-se o modelo de "só sai o que
foi explicitamente permitido", que é mais seguro para o nosso caso.

Vale conhecer, e vale reconsiderar se um dia web vitals virar prioridade. Não vale trocar por ele
um caminho de captura que já funciona e já é mais restritivo.

#### O que o Faro resolve das §2 e §3 — verificado

Ele resolve **uma** das duas lacunas, e é preciso ser exato sobre qual.

**§2 (stack legível): sim.** O `faro.receiver` tem um bloco `sourcemaps` que **desminifica na
ingestão** — remove o `minified_path_prefix`, acha o `.map` e resolve o stack antes de escrever no
Loki. A linha já chega legível, o que é melhor que traduzir na investigação.

Duas armadilhas de configuração, e as duas importam para nós:

- `download` vem **`true`** por padrão, e `download_from_origins` vem **`["*"]`**. Isso faz o Alloy
  buscar source map em qualquer origem que o browser indicar — **superfície de SSRF** num
  componente que roda na mesma máquina do banco. Se adotarmos, isto precisa ser restringido à
  nossa origem, deliberadamente.
- `download: true` pressupõe os `.map` **publicados**, o que expõe o código-fonte. Com
  `sourcemap: 'hidden'` (a opção C) não há `sourceMappingURL` e nada é publicado — então o caminho
  correto para nós é o bloco `location` com `path` no filesystem do Alloy, **não** o download.

**§3 (agrupamento): não.** A documentação do `faro.receiver` não menciona agrupamento, fingerprint
nem deduplicação — ele coleta, desminifica e encaminha. O **fingerprinting é do Grafana Cloud
Frontend Observability**, que é produto pago. Self-hosted (Faro → Alloy → Loki) você recebe linhas
soltas no Loki, exatamente como hoje.

**Consequência para a decisão:** o Faro entrega metade do que falta, e é a metade que a opção C
também entrega. A outra metade — agrupar — continua sendo trabalho nosso **com ou sem Faro**. Isso
reforça a opção C em vez de enfraquecê-la.

#### O presente que a documentação do Cloud dá de graça

Ela descreve o **algoritmo de fingerprint em três camadas**, que é a melhor especificação que
achamos para implementar o nosso:

1. **stack com nomes de função significativos** → normalizar o stack e **filtrar os frames de
   biblioteca**, para que só o código da aplicação entre no hash;
2. **stack minificado, mas com paths válidos** → combinar a **sequência de arquivos** do stack com
   uma versão canônica da mensagem;
3. **sem stack** (erro de rede, assertion) → tipo do erro + mensagem normalizada.

O passo 1 é o que separa um fingerprint útil de um inútil: sem filtrar frames de biblioteca, todo
erro que passa pelo runtime do Svelte agrupa junto. Vale implementar nessa ordem.

---

## 5. Recomendação

**Fazer a opção C agora. Não trazer o Sentry.**

O raciocínio não é "SaaS é ruim": é que das seis capacidades do Sentry, três já temos, uma
recusamos de propósito por ser PII, e as duas que faltam custam ~10 linhas e uma opção de build.
Trazer 16 GB de infraestrutura — ou um script de terceiro numa tela com dado de saúde — para obter
o que uma linha de `vite.config.ts` e um campo de hash entregam é a troca errada.

O que muda a conta no futuro, e vale reavaliar quando acontecer:

- **volume de usuários** a ponto de a triagem manual não escalar → opção D;
- **mais de dois ou três serviços**, quando `request_id` deixa de bastar e trace passa a valer
  (é o gatilho que o doc 62 §12 já nomeia);
- **equipe maior que uma pessoa** cuidando de erro, quando "atribuir e resolver" vira necessidade
  real e não conforto.

Nenhum dos três é o caso hoje.

### Ordem sugerida

| # | Ação | Onde | Fecha |
|---|---|---|---|
| 1 | `build.sourcemap: 'hidden'` + guardar os maps por release | `vite.config.ts` + pipeline | §2 |
| 2 | Campo `fingerprint` no evento de erro, computado no cliente e **recomputado** no servidor | `report.ts` + `client-error/+server.ts` | §3 |
| 3 | Painel "erros por fingerprint" e consulta de "primeira vez visto" | dashboard `00-plantao` | §3 |

O item 2 precisa do teste que o projeto exige: o servidor não pode confiar no fingerprint do
cliente, pela mesma razão dos outros quatro guardas do endpoint — a barreira não pode depender de
código que o usuário consegue editar.
