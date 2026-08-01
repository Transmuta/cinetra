# Decisões de Arquitetura (ADR)

Registro das decisões travadas para levar o Movimento do protótipo (`interface/Movimento.dc.html`) até produção.
Cada decisão tem contexto, alternativas descartadas e consequências. **Uma decisão só muda por um novo ADR.**

Status possíveis: `Aceita` · `Proposta` · `Substituída por ADR-nn`

---

## ADR-001 — O protótipo é a especificação de origem

**Status:** Aceita

**Contexto.** `interface/Movimento.dc.html` são 3.501 linhas numa única classe React (`class Component extends DCLogic`), servida por um runtime próprio (`interface/support.js`). Não é um mock: contém quatro motores de regra reais — resolução de disponibilidade por precedência (`dayPeriods`), detecção de impacto retroativo em mudanças de horário (`futureConflicts`), busca de vagas na fila de espera (`filaVagas`) e coloração de grafo de intervalos para o layout da agenda (`layoutAppts`).

**Decisão.** O protótipo é tratado como **especificação executável e fonte de proveniência**. Toda regra de negócio implementada em produção cita a linha de origem no protótipo. Divergências deliberadas são registradas como `GAP-nn` em [02-regras-e-lacunas.md](02-regras-e-lacunas.md).

**Consequências.** O protótipo é congelado como referência: não recebe features novas. Os 79 screenshots em `interface/screenshots/` viram baseline visual de QA.

---

## ADR-002 — Backend em Elixir + Ash, exposto como API REST

**Status:** Aceita

**Contexto.** O produto é um sistema de gestão de clínica com dado de saúde (LGPD Art. 11), papéis de acesso, agenda colaborativa e agregados pesados (ocupação, faturamento, sessões consumidas). O frontend será SvelteKit, então o backend precisa ser um serviço separado com contrato explícito.

**Decisão.** Elixir + **Ash Framework 3.x** + **AshPostgres**, hospedado num app Phoenix, expondo **AshJsonApi** (JSON:API sobre REST). Phoenix serve também os Channels de tempo real (ADR-004).

**Alternativas descartadas.**

| Alternativa | Por que não |
|---|---|
| SvelteKit fullstack (Node + Drizzle/Prisma) | Um runtime só e deploy mais simples, mas exigiria reimplementar à mão RBAC, criptografia de campo, auditoria e agregados — exatamente as quatro coisas que este domínio mais precisa e que o Ash entrega declarativamente. |
| Phoenix LiveView | Elimina o frontend separado, mas o usuário quer SvelteKit e o protótipo tem interações (drag-and-drop com ghost, pan, layout de raias) que são mais naturais em cliente rico. |
| AshGraphql em vez de AshJsonApi | Melhor para queries de shape variável, mas adiciona codegen e camada de cache no front. O conjunto de telas é fechado e conhecido; REST com `include` do JSON:API basta. **Reavaliar** se a agenda exigir loads aninhados profundos. |

**Consequências.** Ganhamos de graça: `Ash.Policy.Authorizer` para RBAC, `field_policies` para dado sensível, `AshCloak` para criptografia de campo, `AshPaperTrail` para auditoria, e agregados/calculations empurrados para o SQL. Pagamos: dois runtimes, dois deploys, e um contrato de API para manter.

---

## ADR-003 — SaaS multi-clínica desde o primeiro commit

**Status:** Aceita

**Contexto.** O protótipo assume clínica única: `hours`, `holidays` e `settings` são singletons globais no estado. A sidebar, porém, já cita "Centro" como unidade.

**Decisão.** Toda entidade nasce escopada a uma **clínica (tenant)**. A estratégia concreta de multitenancy do AshPostgres é **`strategy :attribute` (coluna `clinic_id`)** — ver [ADR-017](#adr-017--tenancy-por-atributo-clinic_id-em-vez-de-schema-por-tenant) e [01-dominio-ash.md §2](01-dominio-ash.md).

**Justificativa.** Adicionar tenancy depois de existirem dados de saúde em produção é caro e arriscado: exige migração de dados sensíveis, reescrita de todas as policies e revisão de todo índice. Fazer agora custa pouco.

**Consequências.** Toda leitura e escrita passa a exigir tenant no escopo. Um profissional pode existir em mais de uma clínica — isso é uma regra nova, sem precedente no protótipo, e está especificada em [02-regras-e-lacunas.md](02-regras-e-lacunas.md), Parte 3.

---

## ADR-004 — Agenda colaborativa em tempo real via Phoenix Channels

**Status:** Aceita

**Contexto.** O caso normal de uma recepção de clínica são duas ou mais pessoas na mesma agenda ao mesmo tempo. O protótipo não trata disso, e a consequência é concreta: em `filaVagas` → `offerVaga` → `createAppt` não existe reserva entre oferecer uma vaga e confirmá-la, então dois atendentes podem oferecer o mesmo horário ao mesmo tempo.

**Decisão.** Phoenix Channels sobre WebSocket, com `Phoenix.PubSub` alimentado por notificações do Ash. O cliente Svelte usa o pacote npm `phoenix` diretamente, sem passar pelo BFF.

**Consequências.** Precisamos definir granularidade de tópico, reserva de vaga com TTL e locking otimista em remarcação. Está tudo em [02-regras-e-lacunas.md](02-regras-e-lacunas.md), Parte 3, e a arquitetura em [04-arquitetura.md](04-arquitetura.md).

---

## ADR-005 — SvelteKit como BFF, nunca como cliente de banco

**Status:** Aceita

**Contexto.** SvelteKit tem servidor próprio (`+page.server.ts`, form actions). A tentação é ele falar com o Postgres direto.

**Decisão.** SvelteKit roda com `adapter-node` e atua como **Backend-for-Frontend**: seus `load` e `actions` chamam a API do Phoenix, portando o cookie de sessão. **Não existe conexão de banco no serviço web.** A única exceção ao caminho BFF é o WebSocket dos Channels, que o browser abre direto contra o Phoenix.

**Consequências.** Um único lugar aplica as policies do Ash. O BFF pode compor e cachear respostas, e o browser nunca vê um token de API de longa duração. Custo: um salto de rede a mais no SSR — mitigado por colocar os dois serviços na mesma região.

---

## ADR-006 — Frontend em Svelte 5 (runes) + TypeScript

**Status:** Aceita

**Decisão.** SvelteKit 2.x, Svelte 5 com runes, TypeScript estrito, `adapter-node`. Testes e componentes em [03-frontend-sveltekit.md](03-frontend-sveltekit.md); **a estratégia de CSS foi substituída pelo [ADR-010](#adr-010--css-utilitário-com-tailwind-v4)**.

**Consequência principal.** O port de React para Svelte 5 não é mecânico. `this.state` é um objeto plano mesclado por `setState`, e todos os updaters usam `map`/`filter`/spread imutável; em runes você muta proxies `$state` diretamente. Além disso o protótipo tem 1.205 objetos de estilo inline computados a partir de `theme()` e nenhuma classe, que precisam ser reescritos — para utilitários Tailwind sobre uma camada de custom properties, na forma do [ADR-010](#adr-010--css-utilitário-com-tailwind-v4). Os riscos estão catalogados em [03-frontend-sveltekit.md](03-frontend-sveltekit.md), seção 9.

---

## ADR-007 — Dado de saúde é tratado como categoria especial da LGPD

**Status:** Aceita

**Contexto.** O protótipo guarda, sem nenhuma proteção especial: diagnósticos como texto indexável (`patient.tags` contém `'hérnia de disco'`, `'pós-op joelho'`, `'gestante'`), anexos que são laudos e exames (`anexos[patientId]`), queixa clínica na fila (`fila.obs`), encaminhamento médico (`medico`, `crm`) e dados bancários do profissional (`banco`, `agencia`, `conta`, `pix`).

**Decisão.** Estes campos são **dado pessoal sensível (LGPD, Art. 11)**. Consequências arquiteturais, todas obrigatórias para a v1:

1. Criptografia em nível de campo (`AshCloak`) para os campos catalogados em [01-dominio-ash.md](01-dominio-ash.md), seção 6.
2. Trilha de auditoria (`AshPaperTrail`) sobre acesso e mutação de prontuário.
3. `field_policies` do Ash restringindo leitura por papel.
4. Anexos em object storage privado com URL assinada de vida curta — nunca `URL.createObjectURL` persistido, como hoje.
5. Consentimento versionado e datado, com finalidade e revogação. Hoje é um booleano solto (`patient.lgpd`).
6. Política de retenção e rotina de exportação/eliminação a pedido do titular.

**Consequência.** Segurança não é uma fase do roadmap; é um critério de aceitação de cada fatia que toca prontuário.

---

## ADR-008 — Deploy em Fly.io, observabilidade via OpenTelemetry sem vendor lock

**Status:** **Substituída por [ADR-023](#adr-023--produção-na-hostinger-kvm-2-o-a1-da-oracle-fica-adiado-não-descartado)** (2026-07-31) — quanto ao **alvo de deploy**. A metade sobre **OpenTelemetry sem vendor lock continua valendo** e, de fato, foi o que permitiu a troca: o stack de observabilidade é self-hosted (Loki/Grafana/Prometheus/Tempo) e nenhum SDK proprietário atou o projeto a provedor. Fly.io nunca chegou a ser provisionado.

**Decisão.** Dois apps Fly (`cinetra-api` em Elixir, `cinetra-web` em Node), Postgres gerenciado, object storage compatível com S3 (Tigris ou Cloudflare R2). Instrumentação com **OpenTelemetry puro**; o backend de telemetria (Grafana Cloud, Honeycomb) é configuração, não código.

**Justificativa.** Clustering BEAM entre nós Fly deixa o `Phoenix.PubSub` distribuído praticamente de graça, o que o ADR-004 exige. OTel sem SDK proprietário mantém a porta aberta caso um requisito de jurisdição force VPS própria.

**Consequências e alertas.** Dado de saúde de titulares brasileiros: verificar a região do Fly (`gru`, São Paulo) e a localização das réplicas do Postgres antes de qualquer dado real. Detalhes em [05-observabilidade-e-producao.md](05-observabilidade-e-producao.md) e [06-seguranca-e-lgpd.md](06-seguranca-e-lgpd.md).

---

## ADR-009 — Relógio injetável, timezone por clínica

**Status:** Aceita

**Contexto.** O protótipo congela o tempo: `hoje()` retorna a string literal `'2026-06-25'` e o "agora" é a constante `NOW = 702` (11:42). Isso aparece em cerca de dez lugares e contamina toda regra que depende de passado ou futuro — liberar os botões Concluir/Faltou, debitar sessão, expirar regra de fila, calcular vagas.

**Decisão.** Nenhum módulo de domínio lê o relógio do sistema diretamente. O tempo entra como dependência (no Ash, via `Ash.Scope`/contexto da ação). Cada clínica tem um **timezone canônico** persistido; "hoje" e "já começou" são resolvidos nesse fuso, não em UTC nem no fuso do servidor.

**Consequências.** Regras de negócio ficam testáveis com tempo determinístico. Datas viajam pela API como ISO-8601 com offset explícito. O front nunca deriva "hoje" do relógio do browser para decisão de negócio — só para exibição.

---

## ADR-010 — CSS utilitário com Tailwind v4

**Status:** Aceita

**Substitui:** a recomendação de [03-frontend-sveltekit.md §1.1](03-frontend-sveltekit.md#11-css--tailwind-v4-em-duas-camadas) ("CSS vanilla + custom properties, **não** Tailwind") e a consequência de CSS do [ADR-006](#adr-006--frontend-em-svelte-5-runes--typescript).

**Contexto.** A recomendação anterior era CSS vanilla com custom properties e `<style>` scoped, e o argumento contra Tailwind era concreto: o protótipo não tem folha de estilo nem uma única classe — são **1.205 objetos de estilo inline** (`style=${{…}}`, contagem verificada), **zero** `class=`, e toda cor é expressão JS derivada de um switch `dark` via `theme()` ([`:301`](../interface/Movimento.dc.html#L301)) e `tint(hex,a)` ([`:314`](../interface/Movimento.dc.html#L314)). O único CSS real do protótipo são 19 linhas num `<style>` global (reset, 7 `@keyframes`, scrollbar, `focus-visible`). Portar isso para Tailwind seria "dois trabalhos": traduzir cada objeto **e** reconstruir a paleta como config.

**O que mudou.** Aquele argumento mira o Tailwind v3, onde a paleta vivia em `tailwind.config.js` — um arquivo JS divorciado das custom properties, de onde vinha a duplicação. No **v4 a paleta é CSS**: o bloco `@theme inline` emite as custom properties *e* gera os utilitários a partir delas, de uma fonte só. A objeção de "dois trabalhos" deixa de valer. Além disso o padrão mais repetido do protótipo — `tint(cor, alpha)`, 58 chamadas — mapeia direto para o modificador de opacidade (`bg-danger/10`), que é mais limpo que o `color-mix` que a proposta vanilla exigia.

**Decisão.** **Tailwind v4**, via `@tailwindcss/vite`, organizado em **duas camadas** num único `src/lib/styles/app.css`:

1. **Camada de proveniência** — custom properties `--mv-*` e `--cat-*` com os hex **verbatim** do protótipo, trocadas por `[data-theme]`. Preserva a relação auditável "esta cor do protótipo = esta variável" que motivava a decisão anterior.
2. **Camada de utilitários** — `@theme inline` mapeando aquelas variáveis para os namespaces do Tailwind. Como é `inline`, o utilitário gerado referencia `var(--mv-…)` em vez de copiar o valor, então a troca de tema em runtime continua sendo só um atributo no `<html>`.

Dark mode continua por `data-theme` (`@custom-variant dark`), não por `class` nem `prefers-color-scheme` puro — o SSR estampa o atributo e não há flash ([03 §4.4](03-frontend-sveltekit.md#44-dark-mode-via-data-theme-sem-flash)).

**Alternativas descartadas.**

| Alternativa | Por que não |
|---|---|
| Manter CSS vanilla + custom properties (a decisão anterior) | Continua correta e defensável. Perde o modificador de opacidade para os 58 `tint()`, e deixa o layout de cada componente num `<style>` scoped separado do markup. A escolha entre as duas é de preferência de equipe, não de viabilidade — foi feita a favor do utilitário. |
| Tailwind v3 | É exatamente o alvo do argumento original: paleta em `tailwind.config.js`, duplicada em relação às custom properties que o `data-theme` precisa. Reintroduz os "dois trabalhos". |
| Tailwind v4 **sem** a camada 1, hex direto no `@theme` | `@theme` não-`inline` congela o valor no utilitário gerado; a troca por `data-theme` pararia de funcionar. E perderia a proveniência hex→protótipo, que o [ADR-001](#adr-001--o-protótipo-é-a-especificação-de-origem) exige. |

**Consequências.**

- **O volume de trabalho do port não muda.** Os 1.205 objetos inline são reescritos à mão de qualquer forma; o ADR decide no que eles viram, não quantos são. Continua valendo a regra do risco 1 ([03 §9](03-frontend-sveltekit.md#9-riscos-do-port-react--svelte-5)): **não** transcrever objeto-a-objeto.
- **Duas coisas não viram utilitário, por construção.** (a) As cores categóricas: `profColor`/`patientColor` indexam `cat[]` com um `ci` calculado em runtime ([`:315`](../interface/Movimento.dc.html#L315)–[`:316`](../interface/Movimento.dc.html#L316)), e o Tailwind gera classes em build — ficam como custom property setada inline, consumida por `bg-(--var)`. (b) A densidade `--mv-ppm` é aritmética dentro de `calc()` ([`:1228`](../interface/Movimento.dc.html#L1228)), não um valor de escala — segue custom property pura.
- Uma dependência de build a mais e um plugin de formatação (`prettier-plugin-tailwindcss`) para a ordem das classes.
- **Não muda nada em QA visual.** Os 79 PNGs continuam oráculo de aceitação humana, nunca assert de pixel ([07 §7.3](07-estrategia-de-testes.md#73-regressão-visual-contra-os-79-screenshots--avaliação-honesta)) — o motivo é que o framework e o CSS são outros, e trocar vanilla por Tailwind só reforça isso.
- O `<style>` de 19 linhas do protótipo (reset, keyframes, scrollbar, focus) **não** é migrado: reset vem do `@import "tailwindcss"`, e os 7 `@keyframes` viram tokens `--animate-*`. O protótipo permanece congelado ([ADR-001](#adr-001--o-protótipo-é-a-especificação-de-origem)).

---

## ADR-011 — Não há renovação de pacote; o total de sessões é ajustável a qualquer momento

**Status:** Aceita (2026-07-10) · **Reconcilia:** decisão de produto **D7** ([10-decisoes-de-produto-v1.md](10-decisoes-de-produto-v1.md)) × comportamento do protótipo (RN-22, [02 §1.5](02-regras-e-lacunas.md))

**Contexto.** O único fluxo de "Renovar" **alcançável pela UI** — `openRenovar` ([`:336`](../interface/Movimento.dc.html#L336)) → `modalRenovar` ([`:606`](../interface/Movimento.dc.html#L606)) → `confirmRenovar` ([`:590`](../interface/Movimento.dc.html#L590)) — **adiciona sessões ao mesmo pacote**: soma ao `total` e mantém o status `ativo` ([`:600`](../interface/Movimento.dc.html#L600); texto do modal em [`:629`](../interface/Movimento.dc.html#L629), toast em [`:601`](../interface/Movimento.dc.html#L601)) — ou seja, já corresponde ao lado "aumentar" da Decisão. O mecanismo de **pacote-sucessor** — criar um novo pacote com `renovadoDe` e marcar o anterior como `renovado` ([`:358`](../interface/Movimento.dc.html#L358), [`:362`](../interface/Movimento.dc.html#L362); RN-22) — é **código vestigial e inalcançável**: nenhuma UI seta `renovadoDe` e, no único ponto do seed em que ele aparece ([`:108`](../interface/Movimento.dc.html#L108)), o predecessor fica `concluido`, nunca `renovado`. O documento de domínio [01 §4.4](01-dominio-ash.md) modelou esse ramo morto — relação `renovado_de` e o valor `:renovado` no enum `PackageStatus`. A real novidade da operação da clínica não é o acréscimo no mesmo pacote (que o protótipo já faz), e sim a capacidade de **diminuir (−)** o total: o total de sessões de um pacote é simplesmente **editável, para mais ou para menos, a qualquer momento**.

**Decisão.** **Não existe renovação.** Um pacote tem um `total` de sessões que pode ser **aumentado ou diminuído a qualquer momento**, sobre o mesmo registro. Aumentar materializa novas sessões na série (via `computeSerie`, [02 §1.5](02-regras-e-lacunas.md)); diminuir remove sessões futuras ainda não consumidas. O débito acumula sempre no mesmo pacote.

**Consequências.**
- `PackageStatus` perde o valor `:renovado` → fica `[:ativo, :pausado, :cancelado, :concluido]`.
- O `Package` perde a relação `belongs_to :renovado_de` ([01 §4.4](01-dominio-ash.md) a ser corrigido).
- **Não há ação `:renew`.** O ajuste do total vira `add_session`/`remove_session` (individuais ou em lote) sobre o mesmo pacote; `total` é editável enquanto o pacote está `:ativo`. Diminuir só alcança sessões **futuras e não consumidas** — sessões já concluídas/faltadas não são apagadas.
- **Divergência deliberada do [ADR-001](#adr-001--o-protótipo-é-a-especificação-de-origem)** (o protótipo é a spec). Registrada como tal: a produção **não** reproduz o sucessor do protótipo. Catalogar em [02](02-regras-e-lacunas.md) como GAP de renovação.

---

## ADR-012 — Profissional pertence a uma única clínica na v1

**Status:** ~~Aceita (2026-07-10)~~ · **SUPERSEDIDA por [ADR-014](#adr-014--identidade-global-multi-tenant-modelo-vercel) (2026-07-11)** · **Restringia:** [ADR-003](#adr-003--saas-multi-clínica-desde-o-primeiro-commit) (RN-52) · **Reconciliava:** decisão de produto **D15**

> **⚠️ Revertida.** A decisão de produto mudou: adotamos o **modelo de identidade estilo Vercel** — um `User` global pode pertencer a **vários** tenants, com papel isolado em cada, e um profissional **pode** trabalhar em mais de uma clínica. Isso é o [ADR-014](#adr-014--identidade-global-multi-tenant-modelo-vercel). A **RN-52 volta para a v1**. O texto abaixo fica como registro histórico.

**Contexto (histórico).** O [ADR-003](#adr-003--saas-multi-clínica-desde-o-primeiro-commit) abriu explicitamente a porta para um **profissional existir em mais de uma clínica** (RN-52, [02 §3.1](02-regras-e-lacunas.md)) — uma regra nova, sem precedente no protótipo. Isso tornaria o vínculo profissional↔clínica um relacionamento, com agenda, disponibilidade e repasse **por vínculo**, não por pessoa.

**Decisão (revertida).** ~~Na **v1**, um profissional pertence a **uma única clínica**. O multi-clínica de profissional fica para a **v2**.~~

**Justificativa (histórica).** Combinava com `strategy :context`, schema-por-tenant ([01 §2](01-dominio-ash.md)); supunha-se que suportar a mesma pessoa em vários schemas exigiria um modelo de identidade de profissional global — "custo que não se paga na v1". O [ADR-014](#adr-014--identidade-global-multi-tenant-modelo-vercel) mostra que esse custo **não** existe: a identidade global é o **`User`** (no schema público), não o `Professional`; o profissional continua por-schema e é ligado por `Membership.professional_id`. Logo `:context` **sobrevive** e o multi-clínica cabe na v1.

---

## ADR-014 — Identidade global multi-tenant (modelo Vercel)

**Status:** Aceita (2026-07-11) · **Supersede:** [ADR-012](#adr-012--profissional-pertence-a-uma-única-clínica-na-v1) · **Estende:** [ADR-003](#adr-003--saas-multi-clínica-desde-o-primeiro-commit) · **Reconcilia:** decisão de produto **D15** (revertida)

**Contexto.** O produto adota o modelo de identidade do Vercel: uma **conta de pessoa** (`User`) é global e pode pertencer a **vários** espaços (tenants), com **papel isolado por espaço**, trocando entre eles com um seletor. Traduzido para o domínio: uma dona pode ter **mais de uma unidade** (cada unidade é uma clínica/tenant próprio) e um **profissional pode atender em mais de uma clínica**. Isso reabre a RN-52, que o [ADR-012](#adr-012--profissional-pertence-a-uma-única-clínica-na-v1) havia adiado.

**Decisão.**
1. **`User` é a identidade global** e vive no schema público (recurso global de `Accounts`, [01 §2](01-dominio-ash.md)). Uma pessoa = **um** `User`, independentemente de quantas clínicas ela acessa.
2. **`Membership` é o vínculo por-tenant** e carrega o **papel** ([ADR-016](#adr-016--papel-owner-obrigatório-e-perfis-com-capabilities-embarcadas)). A mesma pessoa tem **N memberships** (um por clínica), com papéis possivelmente diferentes em cada.
3. **`Professional` continua por-schema.** Uma profissional que atende em 2 clínicas é **2 registros `Professional`** (um em cada schema), ligados ao mesmo `User` **através do `Membership`** (`Membership.professional_id`, UUID mole por clínica). Agenda, disponibilidade e preço são **por-clínica** — o que é correto, pois variam de fato entre unidades.
4. **Tenant ativo na sessão.** A sessão guarda qual clínica está ativa. O `tenant` do Ash, o `actor.papel` e o `actor.professional_id` derivam **todos** do `Membership` ativo. Trocar de clínica = trocar o membership ativo (ver [09 §8](09-contrato-api.md)).

**Justificativa.** A objeção do ADR-012 era o custo de "identidade de profissional global entre tenants". Ela **desaparece** quando a identidade global é o `User` (público) e o `Professional` permanece **por-tenant**: a mesma pessoa é um `Professional` distinto por clínica, ligado ao `User` pelo `Membership`. Isso vale **independente da estratégia de storage** — o modelo Vercel resolve, de brinde, a resolução de escopo do actor. *(A estratégia concreta era `strategy :context` quando este ADR foi escrito; foi trocada para `strategy :attribute` no [ADR-017](#adr-017--tenancy-por-atributo-clinic_id-em-vez-de-schema-por-tenant).)*

**Consequências.**
- **RN-52 volta para a v1.** O vínculo profissional↔clínica passa a ser **por-membership**, não por-pessoa.
- A escolha de storage do tenant é do [ADR-017](#adr-017--tenancy-por-atributo-clinic_id-em-vez-de-schema-por-tenant) (`strategy :attribute`, coluna `clinic_id`); a exclusion constraint da agenda continua sem `clinic_id` porque `professional_id` é único globalmente ([01 §2](01-dominio-ash.md)).
- **`/auth/me` devolve a lista de memberships/tenants + o tenant ativo**, e existe um endpoint de **troca de tenant** ([09 §8](09-contrato-api.md)).
- **Visão consolidada cross-tenant** (relatórios/faturamento somando várias unidades de uma dona) fica **viável** com o [ADR-017](#adr-017--tenancy-por-atributo-clinic_id-em-vez-de-schema-por-tenant) (query normal por `clinic_id`), diferente do que o `:context` permitia.
- **Multi-unidade *dentro* de um único tenant** (uma clínica com vários endereços que compartilham pacientes/equipe) continua **v2** e é coisa diferente: aqui cada unidade é um tenant **isolado**.

---

## ADR-015 — Autenticação por Google OAuth + Magic Link (sem senha)

**Status:** Aceita (2026-07-11) · **Supera as premissas de senha em:** [01 §Accounts](01-dominio-ash.md), [06 §5](06-seguranca-e-lgpd.md), [09 §8](09-contrato-api.md)

**Contexto.** O login do protótipo é decorativo (campos de e-mail/senha e um botão **Entrar** que só navega, [`:671`](02-regras-e-lacunas.md)). Ao materializar o AshAuthentication, a pergunta é qual(is) estratégia(s). Senha própria arrasta política de senha, verificação contra listas de vazamento, reset por e-mail, bloqueio por tentativas e MFA — superfície e custo altos.

**Decisão.** A v1 tem **duas** estratégias, **sem senha**:
- **Google OAuth** (`oauth2`/`google` do AshAuthentication);
- **Magic Link** (link de uso único por e-mail).

**Não há** estratégia de senha: sem `hashed_password`, sem reset de senha, sem política de senha/breach-list.

**Justificativa.** Elimina a maior parte da superfície de AuthN (senha vazada, reforço de política, reset). Google traz 2FA delegado; magic link é fator de **posse** do e-mail. O convite de membro deixa de "definir senha" e passa a ser um magic link para um `Membership` pendente.

**Consequências.**
- `User` perde `hashed_password`; as ações passam a `:sign_in_with_magic_link` / `:register_with_magic_link` e o fluxo OAuth Google ([01 §Accounts](01-dominio-ash.md)).
- **[06 §5](06-seguranca-e-lgpd.md) encolhe:** saem política de senha, breach-list e reset. **MFA-obrigatório-para-admin** vira **nota opcional** (Google já faz 2FA; magic link é posse).
- O convite ([06 §5](06-seguranca-e-lgpd.md), `saveMembro`) vira "criar membership pendente → magic link → primeiro acesso vincula o `User`".
- **[09 §8](09-contrato-api.md):** `POST /auth/sign_in {email,password}` some; entram request de magic link + callback e o callback OAuth do Google.

---

## ADR-016 — Papel `owner` obrigatório e perfis com capabilities embarcadas

**Status:** Aceita (2026-07-11) · **Estende:** [ADR-014](#adr-014--identidade-global-multi-tenant-modelo-vercel) · **Reconcilia:** RBAC do [06 §6](06-seguranca-e-lgpd.md)

**Contexto.** O protótipo tem 3 papéis como rótulos puros (`admin`, `profissional`, `membro`, [`roleMeta:2408`](../interface/Movimento.dc.html#L2408)), sem enforcement. O modelo Vercel pede um **owner** por espaço, e as permissões devem ser **simples e fixas** — perfis embarcados de "o que pode / o que não pode", não um sistema de papéis customizáveis por tenant.

**Decisão.**
1. **Quatro perfis fixos**, do mais forte ao mais fraco: **`owner` · `admin` · `profissional` · `recepção`** (o `membro` do protótipo = `recepção`). O enum é fechado; não há papéis customizados.
2. **Capabilities embarcadas:** cada papel mapeia, **em código** (um módulo de capabilities, não dado de tenant), para um conjunto fixo de ações permitidas. As policies leem esse mapa.
3. **Invariante do owner:** todo tenant tem **≥1 owner** a todo momento. O `onboard` da clínica torna o criador `owner`. Só `owner` promove/rebaixa owner, mexe em faturamento e exclui/renomeia a clínica. **Não é possível rebaixar nem revogar o último owner** (validação no `Membership`).

**Fronteiras de papel.**
- **owner:** tudo, incluindo faturamento, exclusão/renome da clínica e gestão de owners.
- **admin:** configurações, equipe (convida/remove **exceto** owners), todas as agendas e relatórios. **Não** toca faturamento nem exclui a clínica.
- **profissional:** só a **própria** agenda e seus pacientes (FilterCheck, [06 §6](06-seguranca-e-lgpd.md)).
- **recepção:** opera a agenda de **todos**, sem configurações sensíveis.

**Consequências.**
- O enum `Movimento.Accounts.Role` ([01 §3](01-dominio-ash.md)) passa a `[:owner, :admin, :profissional, :recepcao]`.
- As policies ([01 §7](01-dominio-ash.md), [06 §6](06-seguranca-e-lgpd.md)) ganham `owner` (bypass acima de `admin`) e derivam o papel do **`Membership` do tenant ativo** ([ADR-014](#adr-014--identidade-global-multi-tenant-modelo-vercel)).
- Nova invariante em [01 §8](01-dominio-ash.md): "≥1 owner por tenant".

---

## ADR-017 — Tenancy por atributo (`clinic_id`) em vez de schema-por-tenant

**Status:** Aceita (2026-07-12) · **Supersede:** a estratégia `strategy :context` de [01 §2](01-dominio-ash.md) · **Ajusta:** [ADR-003](#adr-003--saas-multi-clínica-desde-o-primeiro-commit), [ADR-014](#adr-014--identidade-global-multi-tenant-modelo-vercel)

**Contexto.** A v1 começou em **schema-por-tenant** (`strategy :context`): cada clínica num schema Postgres `tenant_<uuid>`, escolhido em [01 §2](01-dominio-ash.md) pelo isolamento físico do dado de saúde. A fatia de fundação já materializou isso (Clinic com `manage_tenant`, `Professional` per-schema, `Repo.all_tenants/0`). Na prática, dois fatores pesaram contra: **(a)** o custo operacional de migrations em N schemas, e **(b)** o produto quer **visão consolidada** para a dona multi-unidade (ADR-014), que com schema-por-tenant atravessa schemas e foi empurrada para a v2.

**Decisão.** Migrar para **`strategy :attribute` com a coluna `clinic_id`**. Recursos por-tenant (`Professional` e os futuros `Appointment`, `Patient`, etc.) viram **uma tabela única** com `clinic_id`; o Ash injeta `WHERE clinic_id = <tenant ativo>` em toda query e preenche `clinic_id` na criação. `User`, `Clinic` e `Membership` seguem **globais** (schema público, sem `multitenancy`). Some `manage_tenant`, `Repo.all_tenants/0` e `tenant_migrations`.

**Justificativa.** O único ponto fraco real do `:attribute` (isolamento lógico, não físico) é **contido pelo Ash**, que auto-filtra e exige tenant nos recursos por-atributo — o modo de falha "esqueci o `WHERE`" do SQL cru quase não existe. Em troca, migrations ficam triviais e a visão consolidada cross-tenant fica viável na v1. **A troca foi feita quando só existia um recurso por-tenant (`Professional`)** — custo quase zero; depois de `Appointment`/`Patient` existirem seria caro.

**Consequências.**
- [01 §2](01-dominio-ash.md) reescrito: a decisão passa a ser `:attribute`; a tabela comparativa foi mantida com o veredito invertido.
- **Código:** `Professional` usa `strategy :attribute, attribute :clinic_id` + `belongs_to :clinic`; `Clinic` sem `manage_tenant`; `Repo` sem `all_tenants/0`; um único conjunto de migrations no schema público.
- **Exclusion constraint da agenda** ([04 §7.1](04-arquitetura.md)): continua **sem** `clinic_id`, porque `Professional` é por-tenant e `professional_id` é único globalmente; `clinic_id` na constraint é defesa-em-profundidade **opcional**.
- **Custo LGPD:** isolamento vira lógico. Mitigação obrigatória (vira checklist em [06 §6](06-seguranca-e-lgpd.md)): **(1)** isolamento imposto **no banco via RLS** ([ADR-018](#adr-018--rls-como-defesa-em-profundidade-da-tenancy-por-atributo)) — não só disciplina de app; **(2)** teste de IDOR no CI conectando como o role restrito; **(3)** `clinic_id` como 1ª coluna dos índices sensíveis ([01 §9](01-dominio-ash.md)).
- **Observabilidade** ([05](05-observabilidade-e-producao.md)): `clinic_id` é atributo/coluna — anexar ao span do OTel fica direto (some a complicação do `search_path`).

---

## ADR-018 — RLS como defesa-em-profundidade da tenancy por atributo

**Status:** Aceita (2026-07-12) · **Fortalece:** [ADR-017](#adr-017--tenancy-por-atributo-clinic_id-em-vez-de-schema-por-tenant) · **Contexto de saúde:** [ADR-007](#adr-007--dado-de-saúde-é-tratado-como-categoria-especial-da-lgpd)

**Contexto.** O [ADR-017](#adr-017--tenancy-por-atributo-clinic_id-em-vez-de-schema-por-tenant) trocou isolamento físico (schema) por lógico (o Ash injeta `WHERE clinic_id = …`). O risco residual: dado de saúde de todas as clínicas convive na mesma tabela, e **uma** query crua (`Repo`/`Ecto`), um `authorize?: false` sem tenant ou um bug de filtro vazaria entre clínicas. Depender só de disciplina de app é frágil demais para LGPD Art. 11.

**Decisão.** Ligar **PostgreSQL Row-Level Security** nas tabelas por-tenant, impondo o isolamento **no próprio banco**. Verificado empiricamente (POC na `professionals`):
1. **Policy por `clinic_id`** em cada tabela por-tenant: `ENABLE`/`FORCE ROW LEVEL SECURITY` + `CREATE POLICY … USING/WITH CHECK (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)`. Sem a GUC setada → **0 linhas (fail-closed)**.
2. **Role de app restrito** (`cinetra_app`, `NOSUPERUSER`/`NOBYPASSRLS`, não-dono): o `phx.server` conecta como ele e fica **sujeito** à RLS. **Migrations rodam como `postgres`** (superusuário, bypassa RLS para DDL). ⚠️ Sem trocar o role, RLS é teatro — superusuário/dono ignoram policies.
3. **GUC por transação** via `Api.Repo.with_clinic/2` (`set_config('cinetra.clinic_id', clinic_id, true)` dentro de uma transação). O ponto de injeção no app é o **plug de scope da sessão** (ADR-014), que embrulha o trabalho por-tenant do request — a finalizar junto da fatia de auth.

**Justificativa.** Devolve, no banco, a garantia "física" que o [ADR-017](#adr-017--tenancy-por-atributo-clinic_id-em-vez-de-schema-por-tenant) abriu mão — sem os schemas. Muda o modo de falha de **"esqueci o filtro ⇒ vaza"** (perigoso) para **"esqueci a GUC ⇒ 0 linhas"** (seguro). É a mitigação #1 do ADR-017, agora imposta pelo Postgres.

**Consequências.**
- **Docker/dev:** o entrypoint cria o role `cinetra_app` + grants, roda migrations como `postgres`, e sobe o server como `cinetra_app` — "mesma experiência", agora com RLS ligada (verificado: endpoints existentes seguem OK).
- **Toda tabela por-tenant** ganha RLS na migration (via SQL de `ENABLE/FORCE/POLICY`); recursos globais (`users`/`clinics`/`memberships`) **não** têm RLS.
- **Teste de IDOR** (mitigação #2 do ADR-017) passa a **conectar como `cinetra_app`** e provar que query crua sem GUC não vê nada e que cross-tenant é bloqueado (INSERT com `WITH CHECK`).
- **Leitura consolidada cross-tenant** (owner multi-unidade) exige um caminho deliberado: GUC com lista de `clinic_id` (`clinic_id = ANY(...)`) ou um role separado — a desenhar na fatia de relatórios.
- **Custo:** operações por-tenant precisam passar por `with_clinic/2` (transação). Sem isso, retornam 0 linhas — falha segura, mas exige o padrão consistente no app.

---

## ADR-019 — Cor semântica é DOIS tokens: fundo fixo e texto por tema

**Status:** Aceita (2026-07-29) · **Motivada por:** [doc 83](83-acessibilidade-analise-completa.md) (ACC-12 a ACC-19) · **Substitui a prática de:** [ADR-010](#adr-010--tailwind-v4-com-o-design-system-do-protótipo-como-fonte)

**Contexto.** `--mv-success`, `--mv-warning`, `--mv-danger` e `--mv-info` nasceram compartilhadas entre os temas (hex verbatim do protótipo) e servindo a **dois papéis**: fundo de badge/chip e cor de texto de aviso. Medido no doc 83: como texto no tema claro elas chegavam a **2,03:1** (`warning`, 23 usos) e como fundo com texto branco a **2,03–3,91:1**. Uma cor não resolve os dois — o que contrasta com branco não contrasta com quase-preto, e escurecê-la para servir de texto apagaria as badges.

**Decisão.**

- **`--mv-<sem>-solid`** é o **fundo** (badge, chip, botão sólido). Fixo nos dois temas — badge é badge — e o texto sobre ele é `--mv-on-solid`, escuro e também fixo. O precedente é a badge ENCAIXE, consertada assim no AN-08.
- **`--mv-<sem>`** é **texto/ícone** (`text-danger` e parentes), e muda **por tema**.
- **Exceção deliberada:** `--mv-danger-solid` escureceu (`#e5484d` → `#d83b40`) para **manter o texto branco**. Botão destrutivo com texto escuro sobre vermelho claro perde a força de aviso.
- O par espelha o que o teal já era (`--mv-teal-solid` + `--mv-teal-text`, hoje `--mv-accent-*` pela ADR-021): não é padrão novo, é o padrão existente estendido às outras quatro.
- **Paleta categórica** (avatar, tipo de atendimento, prioridade) **não** entra nesse modelo: ela vem de lista e é contrato com o `one_of` do servidor (débito **D-3**), então o hex não muda. Ali a cor do texto é **escolhida por cor de fundo** (`textoSobre()` em `web/src/lib/contraste.ts`), porque 5 das 7 cores de avatar reprovam com branco e nenhuma cor única serve às sete.

**Consequências.**

- Os ~91 usos de `text-<sem>` **não mudaram**; quem passou a precisar de sufixo foram os ~5 fundos sólidos (`bg-warning` → `bg-warning-solid`). Usar um pelo outro **reprova no teste**, não em produção.
- Valor de token novo tem de passar em **duas** famílias de fundo: as superfícies e a **própria tinta** (`bg-<sem>/10..14`), onde o fundo já está tingido da cor do texto. Foi a tinta que empurrou os valores finais além do mínimo óbvio — ver doc 83 §11.2.
- A trava é `web/src/lib/styles/contraste.test.ts`, que **lê o `app.css`** em vez de repetir os hex: um teste com os valores à mão concorda com o CSS até o dia em que divergem.
- Mexer nessas cores deixou de ser escolha estética livre. O piso é WCAG AA (4,5 para texto, 3 para indicador de foco), e baixar o gate é decisão humana explícita — a mesma regra do gate de cobertura.

---

## ADR-022 — Dimensão também é token, e o token é nomeado pelo PAPEL

**Status:** Aceita (2026-07-30) · **Motivada por:** [doc 93](93-auditoria-design-system-web.md) (§M-1, §M-2, §M-6) · **Estende:** [ADR-010](#adr-010--tailwind-v4-com-o-design-system-do-protótipo-como-fonte)

**Contexto.** A camada de **cor** já era exemplar: token por papel, trocado por `[data-theme]`, travado por `contraste.test.ts`. A camada de **dimensão** não existia. Medido: **22 tamanhos de fonte em 643 usos** (261 deles em meio-pixel), **13 raios efetivos em 378 usos** (com `rounded-md` e `rounded-lg` valendo o mesmo 8px, e 184 usos escolhendo entre dois nomes idênticos), e quatro `z-index` soltos cuja ordem valia por convenção oral.

Não foi descuido: o design veio de um protótipo HTML com valores em px e a fidelidade foi corretamente priorizada. O custo apareceu depois — `12px` e `12.5px` são indistinguíveis na tela e carregavam papéis diferentes em arquivos diferentes, sem nada dizer qual era qual. Quem escrevia o próximo componente não tinha como acertar: só copiar do vizinho.

E **nenhum dos seis gates do projeto olhava para isso**. Os 1.014 utilitários de valor arbitrário passavam por todos sem tocar em nenhum, porque cada um é sintaticamente válido e individualmente legítimo.

**Decisão.**

- **Fonte:** sete degraus nomeados pelo papel — `micro`, `meta`, `rotulo`, `corpo`, `leitura`, `titulo`, `destaque`. O de 14px chama-se `leitura`, e não `base`, para não haver um nome com dois significados (o `text-base` do Tailwind é 16px).
- **Raio:** quatro — `micro`, `controle`, `cartao`, `full`. Os nomes de TAMANHO do Tailwind (`sm`/`md`/`lg`/`xl`) deixaram de ser sobrescritos: com a escala por papel, mantê-los redefinidos deixaria dois vocabulários vivos para a mesma coisa.
- **Camadas:** `z-cobertura` < `z-painel` < `z-toast` < `z-atalho`, por `@utility` — porque **`z-index` não é namespace temável no Tailwind v4** (medido: `--z-index-*` no `@theme` não gera classe nenhuma). Empilhamento local dentro de um componente continua sendo número cru: ali o contexto é outro.
- **Sem `line-height` nos degraus de fonte**, de propósito: os 643 usos substituídos eram `text-[Npx]`, que não define entrelinha, e acoplar uma moveria o layout do app inteiro por um motivo que não é o desta decisão.

**Consequências.**

- A trava é `web/src/lib/styles/dimensao.test.ts` (valor arbitrário e nome do Tailwind não voltam) e `camadas.test.ts` (a ordem, e que todo `z-<nome>` usado existe). O segundo é obrigatório e não zelo: **utilitário inexistente some em silêncio** — não é erro de build nem de `svelte-check`, o elemento só cai para `z-index: auto`.
- Junto entrou `cor-crua.test.ts`, que fecha o furo simétrico na camada de cor: o `contraste.test.ts` mede pares de TOKEN, então cor escrita à mão é invisível para ele por construção.
- A normalização mexeu em pixels: alguns textos mudaram 0,5–1px e alguns cantos 2px. Foi escolha consciente ao adotar a escala — preservar cada valor teria organizado sem resolver a proliferação.
- A família de marca (landing, telas de entrada) segue isenta: ela é o protótipo em hex, com regras próprias.

---

## ADR-021 — O teal sai do app: o acento de UI é o sage da marca, e a família se chama `accent`

**Status:** Aceita (2026-07-30) · **Completa:** [ADR-020](#adr-020--o-botão-primário-é-o-sage-da-marca-com-texto-branco-abaixo-do-piso-de-contraste) · **Débito que ela cria:** [D-18](50-debitos-tecnicos.md)

**Contexto.** A ADR-020 trocou só o **botão primário** para o sage. O resto do app continuou teal (`#0fb5a6` e derivados) — a faixa do topo, o marcador do "agora", o chip "Hoje", o estado ativo da sidebar, o anel de foco. O app ficou com **duas identidades ao mesmo tempo**, e a pergunta que abriu esta decisão foi exatamente essa: "ainda não mudou em todos os lugares".

**Decisão.** A família inteira do acento passa a ser derivada do sage, **e muda de nome de `teal` para `accent`** — porque um token chamado `teal` valendo um verde-acinzentado é a mentira que o `app.css` existe para não contar. Valores medidos antes de escolher:

| token | era (teal) | é (sage) |
| --- | --- | --- |
| `--mv-accent-solid` | `#0fb5a6` | `#7fa59a` |
| `--mv-accent-hover` | `#0ba294` | `#72958b` |
| `--mv-accent-text` (claro / escuro) | `#067a6f` / `#3fd6c7` | `#3b6d5f` / `#8ec2b3` |
| `--mv-accent-subtle` (claro / escuro) | `#e5f7f4` / `rgba(15,181,166,.16)` | `#ebf4f2` / `rgba(127,165,154,.16)` |
| `--mv-accent-border` (claro / escuro) | `#7fdacd` / `rgba(127,218,205,.45)` | `#9cc9bc` / `rgba(127,165,154,.45)` |

**Por que sage e não outra cor — o anel de foco decidiu.** O acento carrega o anel de `:focus-visible`, e o **rail é escuro nos dois temas**: uma cor escura desaparece ali. Medido: o blue da marca (`#3a5a78`) dá **2,47 sobre o rail** e reprovaria 1.4.11. O sage é claro como o teal era, então o contrato do anel duplo sobrevive **sem remedição** — 6,56 contra os 6,92 do teal. Todos os outros papéis caem dentro de ±0,4 do que o teal media, e o texto sobre o chip até melhorou (4,71 → 5,30).

**O preço, registrado.** O sage tem **saturação 17%** contra os 85% do teal. O acento lê mais discreto — decisão consciente de marca, não descuido. E a matiz do sage (163°) fica a 17° do verde de `success` (146°), contra os 29° que o teal tinha: "Em atendimento" e "Concluído" ficaram cromaticamente mais próximos.

**A paleta de avatar entra; a de tipos de atendimento, não — e as razões são diferentes.**

A **paleta de avatar** (profissional e paciente, `AVATAR_PALETTE`) troca a entrada 1 de `#0FB5A6` para `#7FA59A`. Ela é cor de **dado**, não de marca — o trabalho dela é distinguir pessoas entre si —, então a pergunta que decide é distância perceptual, e ela foi **medida em OKLab** antes da troca:

| paleta | par mais confundível | ΔE_ok |
| --- | --- | --- |
| antes (teal) | `#0FB5A6` ↔ `#009E73` | **0,087** |
| depois (sage) | `#7FA59A` ↔ `#009E73` | **0,111** |

Ou seja: o teal **já era** a cor mais confundível da lista, e o sage afasta o pior par em 28%. Vale registrar o erro que quase barrou esta troca: a primeira análise olhou só a matiz (sage 163°, `#009E73` 164°) e concluiu "duas das sete viraram a mesma". Matiz sozinha não decide — as duas diferem em saturação (17% vs 100%) e luminosidade (57% vs 31%), que é o que o olho usa. **A lição é medir, não supor**, e vale para toda paleta categórica deste app. O contrato de contraste (`textoSobre` devolvendo texto que passa 4,5:1 para as sete cores) continua verde: sage aceita texto escuro a 6,46.

A troca é **frontend puro**: `cor_indice` é um índice 1-based, não um hex — não há cor de avatar no servidor nem migração a fazer.

A **paleta de tipo de atendimento** (`appointment-types.ts` + `@cores`) fica como está. Ali o hex é **persistido** e validado por `one_of` no servidor em **create, update *e destroy*** ([`appointment_type.ex`](../api/lib/api/directory/appointment_type.ex)) — trocar o valor sem migração de dados deixaria toda linha antiga impossível de editar **e de apagar** (422). É trabalho de outra natureza: migração + seed + ~20 arquivos de teste do backend.

**Consequências.**

- **Três tokens valem `#7fa59a` agora**, e a separação é de papel, não de valor: `--mv-sage` (pigmento da marca), `--mv-primary` (botão, ADR-020) e `--mv-accent-solid` (acento, com a família `text`/`subtle`/`border`). Continuam separados de propósito — quem for pagar o D-17 mexe em um sem arrastar os outros.
- **Os 5 `accent-teal` de checkbox viraram `accent-primary`.** `accent-accent` seria ilegível, e o preenchimento de checkbox é de fato a cor do controle primário.
- **O tom `'teal'` do domínio virou `'accent'`** em `StatusMeta['tone']` (agenda) e `ChipTone` (pacotes) — e isso **não era cosmético**: meia dúzia de componentes interpola o tom dentro do nome da variável (`var(--color-${tone})`), então o tom `'teal'` apontaria para um token extinto e o ponto do "Em atendimento" e o chip "Ativo" renderizariam **sem cor**, em silêncio. Ver o novo `web/src/lib/tons.test.ts`.
- **O `contraste-tokens.mjs` foi ressincronizado.** Ele estava medindo `faint`, `teal_text` e as semânticas nos **valores antigos**, e tratava `success`/`warning`/`danger`/`info` como iguais nos dois temas, o que deixou de ser verdade na [ADR-019](#adr-019--cor-semântica-é-dois-tokens-fundo-fixo-e-texto-por-tema). Tabela por tema agora, e as badges medem o `-solid` (o fundo real) em vez do token de texto.
- **A borda do chip continua abaixo de 1.4.11** — 1,83 sobre `surface`, contra os 1,64 do teal. Melhorou junto, mas não passou; virou o débito **D-18**.

---

## ADR-020 — O botão primário é o sage da marca com texto branco, abaixo do piso de contraste

**Status:** Aceita (2026-07-30) · **Abre exceção a:** [ADR-019](#adr-019--cor-semântica-é-dois-tokens-fundo-fixo-e-texto-por-tema) · **Débito que ela cria:** [D-17](50-debitos-tecnicos.md)

**Contexto.** Até aqui `--mv-primary` era o **tema invertido**: quase-preto (`#16181c`) no claro, quase-branco (`#eceef0`) no escuro, com `--mv-on-primary` invertendo junto. Era o par de maior contraste do app (17,77 e 15,28) e cobria botão primário, Toast e chips de grade de pacote — mas não era o **sage da marca**, e o texto escuro sobre verde foi reportado como difícil de ler.

**Decisão.** `--mv-primary` passa a ser **`#7fa59a`** — o mesmo hex de `--mv-sage` — com **`--mv-on-primary: #ffffff`**, igual nos dois temas. O hover escurece para `#72958b` (mesma matiz, ~90%), seguindo a convenção que o acento já usava.

**A exceção, com o número na mesa.** Branco sobre `#7fa59a` mede **2,71:1**. Isso reprova o 4,5 de texto (1.4.3) e reprova até o 3 de limite de componente (1.4.11). A alternativa conforme existia e foi **medida e recusada**: texto escuro `#16181c` sobre o mesmo sage dá **6,56:1** — passa folgado, e é inclusive o que a própria landing usa (`+page.svelte:538` pinta a seção sage com `color:#16241E`). Foi recusada por legibilidade percebida.

Registrar isso é o ponto do ADR: pela regra de [`.claude/rules/testes.md`](../.claude/rules/testes.md), baixar um piso é decisão humana explícita e justificada, nunca atalho para verde. Esta é a decisão explícita.

**Alternativas descartadas.**

- **Sage escurecido preservando a matiz** — `#567b70` (branco a 4,71) ou `#597e73` (4,51), calculados em OKLab. Conformes e visualmente ainda sage, mas não são o hex da marca.
- **`#7fa59a` com texto escuro** — conforme (6,56), é o que a marca já faz na landing. Recusada pelo motivo acima.

**Consequências.**

- **`primary` deixou de inverter por tema.** O Toast do tema escuro era uma pill quase-branca; agora é sage nos dois temas.
- **`--mv-sage` continua existindo com o mesmo hex, e isso é de propósito**: `sage` é o pigmento da marca (logo, landing, gradientes), `primary` é o papel de UI. Quem for pagar o D-17 um dia mexe só em `primary`, sem tocar na marca.
- **O ícone do Toast perdeu a cor como sinal.** `text-accent` (então ainda `text-teal`) sobre sage media **1,06:1** — o check de sucesso literalmente sumia; `text-danger`, 1,20–2,13. Os dois viraram `text-on-primary`, e a variante passou a se distinguir só pela **forma** (check vs alerta). Não fere 1.4.1 porque a cor nunca foi o único sinal ali, mas o teste que provava a distinção media a tinta e teria passado verde sobre um ícone invisível — ele agora mede `lucide-check` vs `lucide-circle-alert`.
- **O chip "próxima" da ficha do paciente saiu de `primary`.** Ele usava `primary` como *texto sobre a própria tinta de 14%* — o padrão que o [ADR-019](#adr-019--cor-semântica-é-dois-tokens-fundo-fixo-e-texto-por-tema) já apontava como o pior caso — e com sage caiu para **2,26:1**. Passou para o par `accent-text`/`accent-subtle` (chamado `teal-*` até a ADR-021), que existe no design system exatamente para chip tingido e é fixado em 4,71. Lição que generaliza: **`primary` agora serve de fundo sólido, não de tinta**; quem precisar de chip tingido usa o par do acento.
- **O gate `e2e/a11y-interno.spec.ts` ganhou uma isenção — a única do arquivo.** Sem ela ficariam 7 nós de `color-contrast` vermelhos para sempre em 5 telas, e gate cronicamente vermelho é gate que ninguém lê. Ela é estreita de propósito: filtra os **nós** cujo HTML casa `bg-primary`, e não desliga a regra `color-contrast` nem usa `.exclude()` (que tiraria aqueles elementos de *todas* as regras). Qualquer outra reprova de contraste na mesma tela continua barrando.
- **Sobra colateral não resolvida**, listada no D-17: `text-primary` (2 links de 11,5px), `border-primary` e `accent-primary` agora pintam sage **sobre** superfície clara, a 2,54–2,71. No tema escuro esses mesmos usos melhoraram (6,56–7,18). O axe não os pegou porque são condicionais e não renderizaram no cenário da varredura — o que é um lembrete de que a varredura mede o que a spec semeia.
- A trava é `web/src/lib/styles/contraste.test.ts`, que **crava o 2,71** em vez de fingir que passa — e que avisa para apagar a exceção se o número um dia subir de 4,5. Antes desta ADR o par `primary`/`on-primary` simplesmente **não era medido por ninguém**: a troca teria passado verde em silêncio.

---

## ADR-013 — Prontuário clínico (LGPD Art. 11) é v2; a v1 tem apenas a ficha do paciente

**Status:** Aceita (2026-07-10) · **Restringe:** [ADR-007](#adr-007--dado-de-saúde-é-tratado-como-categoria-especial-da-lgpd) · **Reconcilia:** decisão de produto **D16**

**Contexto.** O [ADR-007](#adr-007--dado-de-saúde-é-tratado-como-categoria-especial-da-lgpd) trata o prontuário completo como requisito da v1: tags clínicas (diagnóstico), anexos (laudos/exames), encaminhamento, consentimento versionado — tudo LGPD Art. 11, com AshCloak, AshPaperTrail, field policies e purga (o Gate G1 do [08 §6](08-roadmap.md)). A decisão de produto **D16** reduz o escopo: **a v1 não tem prontuário — só a ficha do paciente** (dados cadastrais). Todos os papéis **visualizam** o paciente; o **profissional é somente-leitura** na ficha.

**Decisão.** O **prontuário clínico é v2**. A v1 modela apenas a **ficha** (identificação e contato do paciente). Ficam **fora da v1**: `ClinicalTag`, `Attachment`, `Consent` versionado, e o mapa fino campo×papel de leitura de dado clínico.

**⚠️ Consequência que corrige um exagero anterior — a LGPD encolhe, não desaparece.** Mesmo "só a ficha" carrega, no modelo do [01 §4.6](01-dominio-ash.md), dado **pessoal e alguns sensíveis**: CPF, RG, telefone, e-mail e — se mantidos — **médico/CRM** (encaminhamento revela tratamento) e **convênio/carteirinha**. E a fila de espera tem `obs` = **queixa clínica**. Portanto **não** se pode concluir que "sem prontuário ⇒ sem proteção LGPD". As proteções que **ainda podem valer na v1** dependem das sub-decisões abaixo.

**Sub-decisões que este ADR deixa explicitamente em aberto** (a resolver antes das fatias indicadas):
1. A ficha v1 inclui **médico/CRM/convênio** (sensível) ou **só nome + contato**? — antes de modelar a ficha.
2. **CPF** precisa de cifra (`AshCloak`) + **índice cego** para a busca por documento (`byDoc`, [01 §4.6](01-dominio-ash.md)) na v1? — antes de modelar a ficha.
3. **`fila.obs`**: vira observação **operacional** (não-clínica, sem proteção especial) ou **recebe field policy/cifra**? — antes da Fatia 4.

**Consequências.**
- O domínio `Movimento.Records` ([01 §4.6](01-dominio-ash.md)) encolhe para `Patient` (ficha); `Attachment`/`ClinicalTag`/`Consent` são v2.
- O **Gate G1** ([08 §6](08-roadmap.md)) perde a maior parte do peso na v1, mas **não** é eliminado: o que sobra depende das sub-decisões 1–3.
- A **Fatia 6** do roadmap ([08 §4](08-roadmap.md)) deixa de ser "prontuário completo" e passa a ser "ficha do paciente"; o prontuário migra para v2.
- Não anula o [ADR-007](#adr-007--dado-de-saúde-é-tratado-como-categoria-especial-da-lgpd): quando o prontuário entrar (v2), o ADR-007 volta a valer integralmente.

---

## ADR-023 — Produção na Hostinger KVM 2; o A1 da Oracle fica adiado, não descartado

**Status:** Aceita · **Data:** 2026-07-31 · **Substitui o [ADR-008](#adr-008--deploy-em-flyio-observabilidade-via-opentelemetry-sem-vendor-lock)**

**Contexto.** O ADR-008 dizia "Deploy em Fly.io" e estava vencido há meses sem ADR que o
substituísse — o [doc 95, R-B10](95-analise-infraestrutura.md) registrou isso como achado, contra a
regra da linha 4 deste próprio arquivo (*"uma decisão só muda por um novo ADR"*). No meio do
caminho o [doc 59](59-deploy-dokploy-oci.md) desenhou o alvo como **Oracle Cloud A1 (ARM, Always
Free, 4 OCPU / 24 GB, Vinhedo)** e o [doc 87](87-servidor-hostinger-riscos-e-cuidados.md) o moveu
para uma **VPS Hostinger**, mas nenhum dos dois é um ADR. Este fecha os três.

**O fato novo que decidiu.** Em **15/06/2026 a Oracle cortou o Always Free A1 de 4 OCPU / 24 GB
para 2 OCPU / 12 GB**, sem anúncio público — só atualizando a documentação; instâncias free acima do
novo teto foram desligadas até serem redimensionadas. Se PAYG mantém a franquia antiga é **incerto
por declaração da própria Oracle**: agentes de suporte deram respostas contraditórias e não há
posição pública. O plano do doc 59 foi desenhado inteiro dentro dos 24 GB — inclusive a decisão de
co-hospedar a observabilidade ([doc 62 §3](62-plano-de-logs.md)).

**Decisão.** Produção do Cinetra roda numa **VPS Hostinger KVM 2 (2 vCPU / 8 GB / 100 GB, x86_64,
São Paulo)**, com Dokploy + Traefik e os três stacks (prod, HML, observabilidade) na mesma máquina.
O A1 da Oracle sai do caminho crítico e vira **opção de reavaliação futura**, não plano ativo.

**Alternativas descartadas, com o motivo:**

| Alternativa | Por que não |
|---|---|
| **A1 4/24 apostando que PAYG mantém a franquia** | Depende de uma política que a Oracle não confirma por escrito e que ela já mudou uma vez sem avisar. Custo do erro: ≈ US$ 27/mês surpresa, ou instância desligada |
| **A1 4/24 pagando o excedente** | ≈ US$ 27/mês ≈ R$ 150. Mais barato que o KVM 4 estimado, mas não que o KVM 2 vigente (R$ 108,99) — e paga-se em dólar, com IOF |
| **A1 2/12 grátis** | Abaixo do que a estimativa do doc 87 §2 pedia na época. *(A estimativa depois provou-se errada — ver "Nota" abaixo — mas a decisão foi tomada com a informação de então, e o desempate real foi a incerteza de política, não o número)* |
| **KVM 4 (16 GB)** | O doc 87 §2 o exigia. Medição posterior mostrou que **não era necessário** — R$ 111/mês de diferença por folga que não estava sendo usada |

**Consequências.**

1. **x86_64 em vez de ARM.** O risco nº 3 do [doc 59 §10](59-deploy-dokploy-oci.md) ("build ARM que
   o CI x86 não vê") **deixa de existir**, e o follow-up "confirmar arm64 cedo" do doc 59 §14 sai da
   lista. Ganho de tabela que ninguém tinha escrito: como os runners do GitHub também são x86_64,
   **buildar a imagem no CI passa a ser build nativo** — sem QEMU, sem cross-compile. Isso barateia
   o item 16 da Faixa 1 do [doc 95 §2](95-analise-infraestrutura.md), que é a correção do
   [D-21](50-debitos-tecnicos.md).
2. **Quatro portas root-equivalentes em vez de três** — entra o hPanel, e com ele o restore de
   backup como caminho de escrita total. MFA na conta Hostinger vira controle de segurança, não
   higiene ([doc 87 §3.1](87-servidor-hostinger-riscos-e-cuidados.md)).
3. **Uma camada de firewall gerenciada, com armadilha invertida** — o modelo da Hostinger é
   drop-all; o erro deixa de ser "esqueci a segunda camada" e passa a ser "apliquei grupo vazio e
   derrubei tudo" ([doc 87 §3.2](87-servidor-hostinger-riscos-e-cuidados.md)).
4. **O `compose.dokploy.yml` não muda uma linha.** Toda a mecânica de segurança da Onda 5 — BFF-only,
   isolamento de rede, dois roles de RLS, HSTS no BFF, CSP por ambiente — é independente de provedor.
5. **[doc 59](59-deploy-dokploy-oci.md) fica como plano em espera**, não como runbook ativo. Quem
   provisionar deve ler o 87, não o 59.
6. **Custo:** piso de **R$ 135,08/mês** ([doc 91 §2](91-custos.md)), contra os ≈ R$ 246 que a
   hipótese KVM 4 implicava.

**Nota sobre a qualidade da decisão, porque a lição vale mais que ela.** O KVM 4 quase foi
contratado por causa de uma estimativa que **somava `mem_limit` como se fosse consumo**. Teto de
container existe para conter o pior caso; usá-lo para prever o caso comum superestimou a memória em
**~3×** (8,5–12 GB estimados contra **3,5 GB medidos**, com tudo no ar). Custo evitado: R$ 111/mês
por folga que não seria usada. A regra que fica: **teto declarado não é medição** — e o doc 87 §9
já dizia que a conta era estimativa, o que salvou a decisão de ser tomada às cegas.

**Gatilho de reavaliação.** Voltar a considerar a Oracle (ou o KVM 4/8) se **qualquer** um ocorrer:

- a medição sob carga real do [D-21](50-debitos-tecnicos.md) mostrar aperto de RAM, CPU ou disco;
- a Hostinger subir o preço na renovação (§6 do doc 91 prevê +50–100%) a ponto de cruzar a linha do
  A1 pago;
- a Oracle publicar posição **oficial e por escrito** sobre a franquia em PAYG;
- o teto de 32 GB do KVM 8 virar restrição real — caso em que a resposta provavelmente **não** é
  máquina maior, e sim tirar carga do host: Postgres gerenciado externo
  ([doc 59 §13](59-deploy-dokploy-oci.md)) ou observabilidade em máquina separada
  ([doc 87 §2](87-servidor-hostinger-riscos-e-cuidados.md)).

---

## ADR-024 — O log JSON tem os campos na RAIZ, e o formatter é do projeto

**Status:** Aceita · **Data:** 2026-08-01 · **Diagnóstico completo:** [doc 99](99-o-painel-vazio-e-o-formato-do-log.md)

**Contexto.** Todo painel de 4xx do Grafana abria **"No data"** em produção com o log inteiro
presente no Loki. O `LoggerJSON.Formatters.Basic` aninha o metadata sob a chave `metadata`; o
`| json` do Loki achata objeto aninhado com `_`; o rótulo real era `metadata_status` e os treze
dashboards perguntavam por `status`. Consulta certa sobre campo inexistente **não dá erro — devolve
zero linhas**, e um painel vazio é indistinguível de "não houve nenhum 4xx". Além do 04, estavam
cegos os painéis de status, latência, rota, clínica e job dos dashboards 01, 02, 03, 05 e 09.

**Decisão.** A linha de log da API sai **achatada**: `time`, `severity` e `message` como estrutura,
e todo campo do evento na raiz. Quem faz isso é `Api.LogFormatter`, módulo do projeto, e não um
formatter de prateleira. O BFF já emitia assim — a afirmação do `web/src/lib/server/log.ts` de que
"o formato acompanha o do lado Elixir" passou a ser verdade.

**Alternativas descartadas, com o motivo:**

| Alternativa | Por que não |
|---|---|
| **Mapear `metadata.status` nas consultas dos dashboards** | Conserta os 30 dias já gravados e dispensa redeploy, mas embute o mapeamento numa variável com vírgulas escapadas em 6 arquivos, e todo painel novo precisa lembrar de usar `$parser`. Fica disponível como remendo temporário se a janela antiga importar |
| **`LoggerJSON.Formatters.Elastic`** | Achata, mas renomeia `severity` para `log.level` — e é de `severity` que o Alloy extrai o rótulo `level`. Consertaria os 4xx apagando o `level` em silêncio, repetindo um defeito que o comentário daquele estágio já conta ter cometido |

**Consequências.** Vale para linha nova: o log anterior ao deploy continua aninhado e invisível
para os painéis (legível no Explore por `metadata_*`). O contrato dos campos é normativo — mexer em
`time`/`severity`/`message` quebra o rótulo `level` e a correlação com o Tempo, e há teste guardando
isso, inclusive um que lê o `config/prod.exs` para pegar formatter certo com configuração errada.

---

## ADR-025 — Payload e resposta entram no log, só em 4xx/5xx e redigidos

**Status:** Aceita · **Data:** 2026-08-01 · **Detalhe:** [doc 99 §8](99-o-painel-vazio-e-o-formato-do-log.md)

**Contexto.** A linha de log dizia *que* uma requisição foi recusada (`status`, `route`, `actor`,
`clinic`), nunca **por quê**. Num 422 as mensagens de validação iam na resposta e não eram
registradas em lugar nenhum; a trilha de auditoria não cobre o caso, porque um 422 é recusado
**antes** de a ação rodar e nada chega ao `audit_events`. O sintoma prático: "a secretária não
consegue salvar a ficha" só se investigava reproduzindo.

**Decisão.** A linha de uma requisição **recusada** passa a carregar `payload` (o `body_params`),
`query` (quando há) e `response` (o corpo devolvido, capturado por `ApiWeb.Plugs.CapturarResposta`,
porque no momento da telemetria `conn.resp_body` já é `nil`). Os três passam por `Api.LogRedacao`,
que troca por `"***"` o valor de todo campo de uma **blocklist**, em duas camadas: na origem e como
`redactors:` do formatter.

**As duas escolhas, e o que cada uma custa:**

| Escolha | O que compra | O que custa |
|---|---|---|
| **Só 4xx/5xx** (e não toda requisição) | Payload de paciente fica fora do log em ~todo o tráfego; a retenção de 30 dias do doc 62 continua de pé | Não dá para reconstruir uma operação bem-sucedida pelo log |
| **Blocklist** (e não allowlist) | Investigação legível: `nascimento`, `convenio` e `status` visíveis contam a história de um 422 | **Erra aberto** — campo novo em `Patient` fora da lista vai em claro para o Loki, e nada avisa |

**O risco aceito, explicitamente.** O log vive fora do banco, **sem RLS**, 30 dias, sob uma conta
de Grafana compartilhada e sem trilha de leitura ([doc 95, R-M17](95-analise-infraestrutura.md)).
Payload de paciente ali é uma superfície nova, e a redação a reduz sem eliminá-la. Três coisas
seguram o risco e nenhuma basta sozinha: o teste que cobra a blocklist contra os atributos reais
dos recursos e contra o `Api.Audit.Sensiveis`; a redação por forma do valor no Alloy; e o escopo
restrito às requisições recusadas. **Revisar a lista é uma tarefa recorrente, não um evento** —
campo sensível novo em ficha de paciente ou de profissional precisa entrar nela no mesmo commit.

**Consequência sobre uma decisão anterior.** O [doc 05 §1.3](05-observabilidade-e-producao.md) diz
que corpo de request/response não sai do processo. Este ADR o emenda para o caso 4xx/5xx redigido;
o resto da regra continua valendo, inclusive a proibição de `patient_id` em rota.

---

## Decisões ainda em aberto

Estas **não** estão travadas e precisam de resposta antes de fatias específicas. A lista completa e priorizada está em [02-regras-e-lacunas.md](02-regras-e-lacunas.md), Parte 4.

**Já resolvidas** (2026-07-10, ver [10-decisoes-de-produto-v1.md](10-decisoes-de-produto-v1.md) e ADRs 011–013):
- ~~Pacote tem validade real? Pausar estende?~~ → **D6: sem validade.**
- ~~Presença individual em turma confirma-se?~~ → **D10: sim, por participante.**
- ~~"Renovar" é continuar ou criar sucessor?~~ → **[ADR-011](#adr-011--não-há-renovação-de-pacote-o-total-de-sessões-é-ajustável-a-qualquer-momento): não há renovação; total editável a qualquer momento.**
- ~~Profissional em mais de uma clínica?~~ → **[ADR-014](#adr-014--identidade-global-multi-tenant-modelo-vercel): SIM na v1 — identidade global multi-tenant (reverte o ADR-012).**
- ~~Estratégia de login?~~ → **[ADR-015](#adr-015--autenticação-por-google-oauth--magic-link-sem-senha): Google OAuth + Magic Link, sem senha.**
- ~~Modelo de papéis / owner?~~ → **[ADR-016](#adr-016--papel-owner-obrigatório-e-perfis-com-capabilities-embarcadas): owner·admin·profissional·recepção, capabilities embarcadas, ≥1 owner por tenant.**
- ~~Prontuário/LGPD Art. 11 na v1?~~ → **[ADR-013](#adr-013--prontuário-clínico-lgpd-art-11-é-v2-a-v1-tem-apenas-a-ficha-do-paciente): v2; v1 só a ficha.**

**Ainda em aberto:**

| Tema | Bloqueia | Quando |
|---|---|---|
| Ficha v1 inclui médico/CRM/convênio (sensível) ou só nome+contato? CPF precisa de cifra + índice cego? | Schema da ficha ([ADR-013](#adr-013--prontuário-clínico-lgpd-art-11-é-v2-a-v1-tem-apenas-a-ficha-do-paciente)) | Antes da ficha |
| `fila.obs` (queixa clínica): observação operacional ou campo protegido? | Schema/policy da fila ([ADR-013](#adr-013--prontuário-clínico-lgpd-art-11-é-v2-a-v1-tem-apenas-a-ficha-do-paciente)) | Antes da Fatia 4 |
| Salas / equipamentos como recurso com capacidade (hoje conflito é só por profissional) | Schema | v2 |
| Preço varia por convênio/particular/reembolso? Há repasse ao profissional? | Subdomínio faturamento | v2 |
| Faturamento, guias de convênio, nota fiscal | Subdomínio faturamento | v2 |
| **Visão consolidada cross-tenant** (relatórios/faturamento agregando várias unidades de uma mesma dona) | Leitura entre schemas ([ADR-014](#adr-014--identidade-global-multi-tenant-modelo-vercel)) | v2 |
| Multi-unidade *dentro* de um mesmo tenant (uma clínica, vários endereços, pacientes/equipe compartilhados) — ≠ multi-clínica | Modelo de filial | v2 |
