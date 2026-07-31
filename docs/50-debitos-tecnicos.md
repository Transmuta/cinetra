# 50 — Débitos técnicos aceitos

O que o projeto **decidiu não fazer agora**, com o custo de cada escolha escrito. Não é backlog de
features (isso é o [`08`](08-roadmap.md)) nem decisão de agenda em aberto (isso é o
[`30`](30-decisoes-pendentes-agenda.md)): é a lista do que está torto **de propósito**, para que a
próxima pessoa saiba que é escolha e não descuido.

Cada item responde quatro perguntas: **o que é**, **por que virou débito**, **o que custa hoje** e
**o que o paga**.

---

## D-1 · Eliminação de dados do titular (F8) — só soft-delete por ora

**O que é.** O direito de eliminação da LGPD (Art. 18) — "apaguem meus dados". Desenhado em
[`30 §F8`](30-decisoes-pendentes-agenda.md) e [`06 §2.5`](06-seguranca-e-lgpd.md), ancorado no
**Paciente**, que é onde mora o dado pessoal.

**Por que virou débito.** Não é limitação técnica: **falta a resposta jurídica**, e ela é o coração
da feature. Fisioterapia é regulada pelo **COFFITO, não pelo CFM** — os "20 anos" que todo mundo
cita não se aplicam automaticamente ([`06 §2.4`](06-seguranca-e-lgpd.md)). Sem o prazo de guarda, o
sistema não consegue responder a única pergunta que a eliminação faz: *este dado é eliminável ou
está sob guarda legal?* E o erro é assimétrico — não apagar rende multa da ANPD; apagar prontuário
dentro do prazo rende problema com o conselho.

Há ainda uma divergência **entre os próprios docs**, a resolver antes de qualquer linha: o
[`30`](30-decisoes-pendentes-agenda.md) fechou em *hard delete*; o [`06 §2.5`](06-seguranca-e-lgpd.md)
descreve `:request_erasure` — uma **solicitação** com revisão humana, "nunca um `DELETE` cego". São
duas features diferentes.

**O que custa hoje.** Nada operacional: **o projeto inteiro é soft-delete/arquivamento** e continua
assim. `Patient`, `Professional`, `AppointmentType` e `Package` arquivam (`ativo`/status); o
agendamento tem `excluded_at` ([`40`](40-exclusao-de-agendamento.md)). A única deleção real do
sistema é a de `Attendance` (sair da turma). O custo é de **conformidade**, e só aparece no dia em
que a primeira clínica receber um pedido de exclusão.

**O que o paga.** Uma pergunta ao jurídico: *qual resolução do COFFITO rege a guarda de prontuário
de fisioterapia e qual o prazo?* Com ela respondida, o F8 vira fatia normal. Parte do caminho já
está pago: a Onda 5 trocou 4 FKs para `SET NULL` porque, do jeito antigo, **nenhum `User` que já
tivesse criado um agendamento seria apagável** ([`46 §H64`](46-onda-5-producao.md)), e
`on_delete_test.exs` já vigia a semântica de cada FK.

---

## D-2 · Quatro FKs sem índice liderando

**O que é.** `attendances.appointment_id`, `attendances.patient_id`, `packages.patient_id` e
`package_schedules.package_id` não têm índice em que a coluna da FK **lidere** — que é o que a
checagem do `DELETE` do pai usa (`WHERE fk = $1`). Medido em [`48 §2f`](48-onda-6-soltas-e-limpeza.md).

**Por que virou débito.** O caminho que os usaria **não existe**: os pais não têm ação `destroy`.
Criar um índice que ninguém lê é peso a cada `INSERT` numa tabela quente — é a lição do **D-A**
([`35`](35-plano-execucao-backlog.md)), que o projeto já pagou uma vez.

**O que custa hoje.** Zero — nenhuma dessas checagens dispara. Medido: `attendances.appointment_id`
é **Seq Scan de 345 buffers** por agendamento apagado; os outros três são baratos ou irrelevantes
no volume atual.

**O que o paga.** O **D-1 (F8)**: é ele que torna a deleção real, e é junto dele que o índice entra
— medindo o caminho inteiro, não em antecipação. `index [:coluna], all_tenants?: true` + migration
`CONCURRENTLY`. A lista está declarada em `@sem_indice_liderando_conhecidas`, no
`on_delete_test.exs`: sair dela é trabalho declarado, entrar nela sem querer é impossível.

---

## D-3 · A paleta de cores vive em duas linguagens

**O que é.** O `one_of` de `Api.Directory.AppointmentType` é a autoridade; `TYPE_COLORS`/`TYPE_ICONS`
em `web/src/lib/appointment-types.ts` repetem a lista para a tela só *oferecer* o que a API aceita.

**Por que virou débito.** Nenhum compilador liga os dois lados (linguagens diferentes, e um
container **não enxerga** o diretório do outro — `./api:/app` e `./web:/app`).

**O que custa hoje.** Quase nada, e é deliberado: acrescentar uma cor é **acrescentar nos dois
lados**, e há uma *tripwire* em cada um (um teste que fixa a lista e manda mudar o irmão junto).
Pior caso se alguém ignorar as duas: a pessoa escolhe uma cor que a API recusa e recebe um 422 em
inglês.

**O que o paga.** Se um dia incomodar: a API **servir** a paleta no `GET /api/appointment-types` e o
modal consumi-la. É mudança de contrato para um risco cujo pior caso é cosmético — por isso não foi
feita.

---

## D-4 · O e2e fora do CI

**O que é.** `e2e/switch-clinic.spec.ts` percorre criar conta → magic link → onboarding → segunda
clínica → trocar tenant. Roda **local**, contra o `docker compose`; o job do CI foi **removido**.

**Por que virou débito.** O e2e precisa da stack inteira (API, banco, caixa de e-mail de dev) e o
workflow sobe só o `web`. Um job que pula com aviso é ruído com cara de cobertura.

**O que custa hoje.** A jornada de troca de tenant só é verificada por quem rodar o e2e à mão. As
peças isoladas continuam cobertas pela suíte de unidade; o que não é coberto automaticamente é a
**costura** entre elas.

**O que o paga.** Um estudo de e2e (previsto) que decida a forma — inclusive como autenticar contra
um ambiente sem `dev_routes`. O alvo já é configurável por `E2E_BASE_URL`/`E2E_API_ORIGIN`
(`web/e2e/README.md`), então apontar para hml/produção é mudar variável, não código.

---

## D-5 · A janela entre analisar e escrever, no A3

**O que é.** O gate de conflitos futuros (A3/D12) faz o recheck **dentro** da transação que grava
([`48 §5`](48-onda-6-soltas-e-limpeza.md)), como o `CheckAvailability` faz ao agendar. Sob
`READ COMMITTED`, ainda cabe uma janela: um agendamento que **committa** entre o `SELECT` da
análise e o `COMMIT` da escrita não é visto.

**Por que virou débito.** Fechá-la de verdade exige `SERIALIZABLE` ou lock explícito sobre a agenda
futura da clínica — trocar uma corrida rara por contenção em tabela quente.

**O que custa hoje.** Um agendamento fora do expediente que nunca apareceu em lista nenhuma.
Visível na agenda, remarcável, sem perda de dado. Precisa das duas ações na mesma fração de segundo.

**O que o paga.** Se aparecer no uso real: `SELECT ... FOR SHARE` na janela analisada, ou o nível de
isolamento mais forte só nessa transação.

---

## D-6 · Anexos sem antivírus

**O que é.** [`06 §7.4`](06-seguranca-e-lgpd.md) exige varredura antivírus antes de um anexo ficar
disponível para download. A fatia de anexos ([`51`](51-ficha-anexos-e-storage.md)) entregou os
**outros cinco** itens do §7 — bucket privado, URL assinada de vida curta, sniffing de content-type
real, limite de tamanho no servidor e `Content-Disposition` na assinatura — e **não** este.

**Por que virou débito.** Não é dificuldade técnica: é um **serviço a mais para hospedar e manter**.
ClamAV quer processo próprio, memória (~1 GB só para a base de assinaturas), atualização diária
dessa base e monitoramento — e, se ele cair, ou o upload para de funcionar ou a varredura vira
teatro. Decisão humana explícita em 2026-07-27, tomada com o custo na mesa.

**O que custa hoje.** Um **PDF com payload malicioso passa**. É o risco real e ele não é zero.

O que fica no lugar não é nada:

- **allowlist fechada** (`application/pdf`, `image/png`, `image/jpeg`, `image/webp`) — sem
  `image/*`, então **SVG não entra**, e com ele sai a classe inteira de XSS por anexo;
- **magic bytes conferidos no servidor**, contra os bytes lidos do próprio bucket, e comparados com
  o tipo declarado — um `.pdf` que é executável não vira anexo;
- o arquivo **nunca é renderizado na origem do app**: sai de `*.r2.cloudflarestorage.com`, em aba
  separada, sem alcançar sessão, cookie ou DOM nossos;
- **quem abre é owner/admin/recepção**, e cada abertura fica em `attachment_events`.

Sobra o caso de o próprio operador da clínica abrir um PDF hostil que ele mesmo subiu — o vetor de
phishing interno, não o de invasão do sistema.

**O que o paga.** Um ClamAV como serviço (Fly machine própria, ou o scanner de um provedor). Quando
entrar, o desenho já o espera: o anexo nasce `:pendente` e a conferência vira job Oban em vez de
síncrona, `Api.Records.AttachmentStatus` ganha `:rejeitado`, e a UI já tem o estado de espera.

---

## D-7 · A URL de upload continua válida depois do `confirm`

**O que é.** A URL de `PUT` assinada do anexo vale **10 minutos**, e nada a marca como consumida.
Depois de o `confirm` aprovar tamanho e magic bytes, quem tem a URL ainda pode reescrever a mesma
chave. Medido no bate-volta ([`54 §5a`](54-bate-volta-anexos.md)): a linha continua dizendo
`application/pdf` / `disponivel` enquanto o objeto no bucket virou `<script>alert(`.

**Por que virou débito.** O TTL **não foi escolhido por segurança, foi escolhido pelo arquivo**.
50 MB em conexão de 1 Mbps levam 6min40; em 512 kbps, 13min20. Cortar para 3 min exigiria 2,2 Mbps
sustentados e quebraria upload em qualquer clínica fora de fibra — troca ruim para um risco que
exige funcionário autorizado sabotando o próprio arquivo.

**O que custa hoje.** Integridade do artefato guardado, e só. O atacante precisa ser membro
**autorizado**, trocar o **próprio** upload, dentro da janela, por conteúdo de **exatamente o mesmo
tamanho** (o `content-length` está dentro da assinatura). E o `response-content-type` da URL de
leitura é pinado ao tipo **conferido**, então HTML posto ali é servido como `application/pdf` e não
executa — não há caminho de XSS.

**O que o paga.** Escrita condicional: assinar o `PUT` com `If-None-Match: *`, que faz o segundo
`PUT` na mesma chave responder 412. Fecha sem tocar no TTL e sem custo por download. **Não foi
verificado que o R2 suporta** — não havia bucket na auditoria. Teste de 2 comandos quando houver:
subir um objeto, tentar subir de novo com o header; `412 Precondition Failed` resolve o débito.
Se não suportar, a alternativa é reconferir os magic bytes na emissão de cada download (+1 ida ao
R2 por clique em "abrir", que hoje custa zero).

---

## D-8 · Emissão de URL assinada sem rate limit

**O que é.** `POST /patients/:id/attachments` cria uma linha `:pendente` e assina uma URL, sem
limite de taxa. O `ApiWeb.Plugs.RateLimitAuth` cobre só as três rotas de auth — **não existe rate
limit global** no projeto.

**Por que virou débito.** O teto do estrago **já é a cota**, não a velocidade: 100 anexos por
paciente, contando os `:pendente` justamente para o abuso não passar por aí. Um rate limit
reduziria a taxa, não o máximo.

E o caminho barato não serve: a cláusula genérica do plug chaveia por `request_path`, que no
presign contém o **UUID do paciente** — o balde fragmentaria por paciente e viraria 10 × N
pacientes por janela. Um limite que existe no código e não bounda nada é pior que nenhum.

**O que custa hoje.** Pouco, e medido: linha de anexo ≈ 200 bytes, então mil presigns abusivos são
200 KB que a poda das 24 h leva. Para gastar armazenamento de verdade o atacante precisa **subir
bytes**, e aí esbarra no próprio link da clínica (2,5 TB a 5 Mbps ≈ 46 dias de upload saturado).
O ator, hoje, é sempre um funcionário identificado — owner, admin ou recepção.

**O que o paga.** Generalizar o plug para `ApiWeb.Plugs.RateLimit` com `bucket:`/`limit:`/`scale:`
por opção (chave = `{bucket_nomeado, actor}`, sem path), mais pipeline e scope no router: ~90
linhas e ~2–3 h com teste. **O gatilho é o ator mudar** — portal do paciente, envio de exame por
link. Enquanto quem sobe anexo é funcionário da clínica, a cota basta.

> Armadilha do teste: o plug é **no-op fora de produção** (`rate_limit_enabled`). Sem
> `Application.put_env(:api, :rate_limit_enabled, true)` no `setup`, o teste passa verde sem
> exercitar nada — ver `rate_limit_auth_test.exs:10`.

---

## D-9 · A ficha gasta uma chamada de anexos para quem não pode vê-los

**O que é.** O `load` da ficha dispara seis chamadas à API em paralelo, e a de anexos vai **também
para o `profissional`**, que recebe 403 (anexo é owner·admin·recepção, [`51 §3`](51-ficha-anexos-e-storage.md)).

**Por que virou débito.** A correção óbvia é pior que o problema: para o `load` saber o papel antes
de decidir, ele precisa de `await event.parent()` — o que põe os seis fetches **em série atrás do
layout** e cobra um round-trip de **todos os papéis, em toda abertura de ficha**, para poupar seis
queries a **um**. É o mesmo trade-off que o `load` da agenda já documenta e recusa.

**O que custa hoje.** Seis queries por ficha que um profissional abre — medido: cada chamada à API
custa ~4 queries só para resolver a sessão (`tokens`, `memberships`, `clinics`, `users`) mais uma
de paciente. Trinta fichas por dia por profissional = 180 queries/dia; cinco profissionais = ~900.
Contra as dezenas de milhares que a agenda emite.

**O que o paga.** O papel ficar disponível sem esperar o pai — por exemplo, o `hooks.server.ts`
resolvendo a sessão para `event.locals` uma vez por request. Aí a checagem sai de graça e o débito
cai junto com outros do mesmo tipo. É refatoração de fundação, não desta fatia.

---

## D-10 · Sem preview por PR — a revisão é no HML

**O que é.** O deploy no Dokploy/OCI ([`59`](59-deploy-dokploy-oci.md)) tem dois ambientes fixos:
`main → prod` e `develop → HML`. **Não** há deploy efêmero por Pull Request (o link automático por
branch que o Dokploy sabe gerar).

**Por que virou débito.** A feature de preview do Dokploy foi desenhada para app de um serviço, e a
stack aqui tem três atritos que a quebram por padrão: **(a)** a CSP é assada no **build** (`kit.csp`),
então cada preview precisaria do `API_PUBLIC_ORIGIN` templatizado com o seu próprio domínio, senão
a guarda de boot derruba o web; **(b)** cada preview precisaria do **próprio Postgres + migrate**,
senão migrations de branches diferentes se atropelam num banco compartilhado; **(c)** o **Google
OAuth não aceita redirect URI wildcard**, então login por Google não funciona em domínio efêmero —
só magic link. É infra de verdade, não um checkbox.

**O que custa hoje.** Nada operacional: o **HML no `develop`** cobre a revisão pré-produção, no
mesmo ARM e mesmo compose que prod. O que se perde é o conforto de um link isolado por PR aberto —
duas branches em revisão disputam o mesmo HML.

**O que o paga.** Volume de PRs simultâneos que justifique a complexidade, com as três soluções
desenhadas de propósito (CSP por domínio de preview, banco efêmero por PR, auth por magic link no
preview). O HML já mitiga o grosso do risco; o preview entra por cima depois, sem refazer nada.

---

## D-11 · Retenção de dado: quatro relógios diferentes, e um sem relógio nenhum

**O que é.** Não há política de retenção única. Cada tabela que cresce sozinha ganhou o seu número
no momento em que foi construída, e a comunicação com o paciente ([`52`](52-comunicacao-com-o-paciente.md))
nasceu **sem número nenhum**:

| Tabela | Retenção | Onde foi decidida |
| --- | --- | --- |
| Trilha de auditoria | **90 dias** | `Api.Housekeeping.PruneTrail`; o prazo mora em `Api.Audit.retencao_dias/0` (doc 63, D-Aud5 — era 365) |
| Caixa de notificações | 90 dias (lidas) / 365 (não lidas) | `Api.Housekeeping.PruneNotifications` (#54) |
| Anexos abandonados | poda diária | `Api.Housekeeping.PruneAttachments` (doc 51). A **trilha de acesso** saiu daqui: mora em `audit_events` e segue os 90 dias acima (doc 63) |
| **`messages` / `message_opt_outs`** | **nenhuma** | — |

**Por que virou débito, e por que ele é do tipo bom.** A decisão de esperar é deliberada
(2026-07-28): retenção é pergunta **transversal e jurídica**, não técnica — quanto tempo se
consegue provar que a clínica avisou, contra quanto tempo se pode guardar dado pessoal de um
paciente. Decidir tabela a tabela é como se chega a quatro réguas que ninguém sabe justificar
depois; a quarta seria esta. Fica para uma passada única, com orientação jurídica, valendo para
**todos** os casos de uma vez.

**O que custa hoje.** Quase nada, e por dois motivos que valem juntos:

- a fatia de comunicação **ainda não está em produção** (falta a chave do Resend e o domínio
  verificado — doc 52 §14.5), então `messages` não cresce;
- quando crescer, o volume é conhecido. Medido na clínica de volume do dev: ~2.200 presenças/mês,
  o que dá ~4.400 mensagens/mês com confirmação + lembrete ligados, ou **~53 mil linhas ≈ 19 MB por
  ano por clínica** (100 mil linhas ocupam 36 MB). A leitura não degrada: a timeline lê **um**
  agendamento por vez, pelo índice `messages_appointment_index`.

**O ponto de atenção.** A linha de `messages` **é** a prova de que se avisou — foi por isso que ela
dispensou o `AshPaperTrail` (o registro já é o histórico). Então a poda, quando vier, apaga
evidência, não lixo: o número escolhido precisa cobrir a janela em que alguém ainda pode contestar
*"ninguém me avisou"*. Do outro lado, `destino` guarda e-mail ou telefone **congelado** — dado
pessoal parado, que a minimização da LGPD desaconselha manter para sempre.

**O que o paga.** Uma conversa com advogado sobre retenção, e então **um** `Api.Housekeeping.PruneMessages`
no molde dos três existentes (~1 h), mais o realinhamento dos outros números à régua única que sair
de lá.

---

## D-12 · Remarcar não descarta a confirmação parada na fila

**O que é.** `Api.Messaging.Notifier` retira da fila (`:descartada`) tudo que ainda não saiu quando
o bloco é **cancelado** ou **excluído** — porque nos dois casos a sessão de que a mensagem fala
deixou de existir. **Remarcar não entra nessa lista**, e o caso é real: dentro da janela de
silêncio (§7), remarcar às 22h45 deixa a confirmação das 22h parada com o horário **antigo** nas
`vars` congeladas. Às 8h o paciente recebe "sua sessão está marcada para 28/07 às 12:00" e, logo
depois, "sua sessão mudou para 30/07 às 13:15".

**Por que ficou de fora, em vez de virar mais uma linha no notifier.** Descartar aqui produz o
defeito oposto: o paciente receberia só o "sua sessão **mudou**" sem nunca ter recebido o "sua
sessão está marcada" — um aviso sem antecedente, para alguém que talvez nem soubesse do
agendamento. As duas saídas erram, e a escolha entre elas é de copy, não de código: ou a
remarcação passa a se bastar (texto que anuncia o horário novo sem pressupor o anterior, e aí o
descarte fica correto), ou a confirmação parada é **reemitida** com o horário novo em vez de
descartada.

**O que custa hoje.** Duas mensagens em sequência, a primeira desatualizada, e só na janela entre
o agendamento e o fim do silêncio — que é onde a remarcação é menos provável (ninguém remarca de
madrugada com frequência). Fora da janela de silêncio o problema não existe: a confirmação já
saiu antes de a remarcação acontecer.

**O que o paga.** A decisão de copy acima (~30 min de produto) e então uma cláusula no notifier —
o mecanismo de descarte já está construído e testado.

---

## D-13 · Os documentos legais estão no ar com placeholder e sem revisão jurídica

**O que é.** `/privacidade` e `/termos` ([doc 81](81-paginas-legais-e-aceite.md)) foram escritos
descrevendo o que o sistema realmente faz, mas **quatro campos do controlador são marcadores**
(`[RAZÃO SOCIAL]`, `[CNPJ]`, `[ENDEREÇO COMPLETO]`, `[COMARCA/UF]`, mais `[NOME DO ENCARREGADO]`), e
**nenhum advogado leu o texto**.

**Por que virou débito.** Decisão explícita de 2026-07-29: preencher a identificação com dado
inventado seria pior que deixá-la pendente, e o dado real ainda não existe. O marcador é visível de
propósito, e `legal.test.ts` **falha** se alguém trocar o placeholder por um CNPJ plausível — a
pendência está declarada, não esquecida.

**O que custa hoje.** Duas coisas, de gravidade diferente:

- **Bloqueia a publicação.** O art. 9º da LGPD exige a identificação do controlador; uma política
  que diz `[CNPJ]` não cumpre o dever de informação, e o texto está indexado (entrou no sitemap).
- **Uma seção promete o que não existe.** *Teste grátis, planos e pagamento*, nos Termos, descreve
  cobrança, renovação e reajuste, e **não há cobrança implementada** — é a mesma promessa comercial
  que a landing já fazia ([doc 57](57-seo-e-performance-da-landing.md), respostas `cancelar` e
  `migracao` do FAQ). Enquanto o produto não cobra, ela é intenção, não descrição.

**O que o paga.** Os dados cadastrais da empresa e do encarregado (minutos, quando existirem) e uma
leitura por advogado com a lista de afirmações técnicas do doc 76 §3 na mão — ela é o que permite
revisar o texto sem reengenharia do produto. A seção de planos se resolve sozinha quando a cobrança
existir; até lá, é candidata a sair.

---

## D-14 · O aceite dos documentos não fica registrado em lugar nenhum

**O que é.** No `/criar-conta`, o aceite dos Termos e da Política é uma **nota** ("ao criar sua
conta … você concorda com …"), não uma caixa de seleção, e **nada é gravado**: nem data, nem versão
do documento, nem qual caminho de cadastro foi usado.

**Por que virou débito.** Decisão de produto de 2026-07-29, e a razão é sólida: o cadastro tem dois
caminhos, e o do Google é um `<a>` de navegação completa que caixa nenhuma trava sem JavaScript
(doc 76 §1). Uma caixa que vale só no magic link daria **aparência** de controle. Persistir o aceite
é a outra metade, e essa custa mais: campo no `User`, migração, o aceite viajando no token do magic
link, e o caminho do Google carimbando no callback.

**O que custa hoje.** Aceite por nota é aceite **presumido**: em disputa, a Cinetra consegue mostrar
que o texto estava na tela naquela versão do código, mas não que *aquela pessoa* passou por ele em
*determinada data*. Some-se a isso `VERSAO`/`ATUALIZACAO` serem constantes do código: quando o texto
mudar, ninguém saberá qual versão cada conta aceitou, nem a quem reavisar. Enquanto a base é pequena
e nova, o risco é baixo; ele cresce com a base e com a primeira alteração de termos.

**O que o paga.** `termos_aceitos_em` + `termos_versao` no `User`, carimbados na ação de sign-in
(serve para os dois caminhos, porque os dois passam por lá), e a versão saindo de `legal.ts` para o
banco no momento do aceite. Meio dia, e casa naturalmente com D-13: mudar de versão só faz sentido
depois que o texto for o definitivo.

---

## D-15 · O gate `:rls` não alcança leitura interna: a GUC fica pendurada no sandbox

**O que é.** `mix test --only rls` roda como `cinetra_app` (NOBYPASSRLS) e é o que prova que uma
leitura por-tenant tem `in_clinic`/`with_clinic`. Ele prova isso **da porta de entrada**. Uma
leitura *interna*, mais adiante no mesmo caminho, ele **não** alcança: o sandbox roda o teste
inteiro numa transação só, então a GUC que o primeiro `in_clinic` pendurou com `SET LOCAL` continua
valendo para tudo o que vier depois — inclusive para a leitura que esqueceu de setá-la.

**Como foi medido** (bate-volta de 2026-07-29, [doc 77](77-bate-volta-observabilidade-e-pacotes.md)):
removi o `in_clinic` de `Api.Packages.checar_profissional/2` — uma leitura por-tenant nova dentro do
caminho de escrita de `adjust_grade/3` — e rodei o gate como `cinetra_app`. Resultado: **0
falhas**. O mesmo teste com a regra mutada continuou verde. A necessidade só apareceu no `psql`:

```
cinetra_app, SEM a GUC : 0 profissionais
cinetra_app, COM a GUC : 1 profissional
```

**O que custa hoje.** Uma falsa sensação de cobertura, que é o pior tipo. O
[`.claude/rules/migrations.md`](../.claude/rules/migrations.md) e o moduledoc de
`Api.RlsSmokeTest` apresentam o gate como a resposta para "esqueci o `in_clinic`", e ele é a
resposta **parcial**. Um conserto que introduza leitura interna sem GUC passa nos três gates do CI
e quebra em produção — recusando toda operação, porque a RLS devolve zero linhas e o código lê isso
como "não existe".

**O que o paga.** Duas saídas, e a segunda é a barata:

- rodar cada teste `:rls` em transação própria (mexe em `DataCase`, sandbox e `async` — caro);
- **anotar a regra**: leitura por-tenant nova em caminho de escrita se prova por `psql` sob
  `cinetra_app`, não pelo gate.

**Metade paga (2026-07-29).** A segunda saída foi feita: a regra 3 de
[`.claude/rules/migrations.md`](../.claude/rules/migrations.md) passou a dizer o alcance do gate,
com a medição da mutação e os dois comandos de `psql` (conferidos: 0 sem a GUC, 1 com). Isso também
fecha uma lacuna que ninguém tinha notado — o CLAUDE.md **já** mandava ler aquele arquivo a
respeito de RLS, e o texto não estava lá.

**O que continua em pé** é a primeira saída: enquanto o sandbox rodar um teste por transação, o gate
segue cego para leitura interna. O débito é o *limite do arnês*, não a falta de aviso — a diferença
é que agora quem escreve teste de RLS é avisado de que precisa mutar a regra para saber se o teste
vale algo.

---

## D-16 · `x-forwarded-for` é confiado pelo primeiro item, e o proxy anexa

**O que é.** [`ApiWeb.ClientIp`](../api/lib/api_web/client_ip.ex) resolve o IP do cliente pegando
`List.first/1` do `x-forwarded-for`. O Traefik **anexa** o IP real ao valor que chegou, em vez de
substituí-lo — então um cliente que mande `X-Forwarded-For: 9.9.9.9` produz `9.9.9.9, <ip real>`, e
o primeiro item, que é o que vale, é o que o atacante escreveu.

**Como apareceu.** Achado de raspão no rename para Cinetra
([doc 84 §5](84-rename-movimento-para-cinetra.md)), ao consertar o problema vizinho — o default
`["fly-client-ip"]` que sobreviveu à saída da Fly. Esse foi consertado com teste de regressão; este
aqui é anterior e independente, e **não** foi tocado.

**O que custa hoje.** Pouco, por acidente de topologia: a API é interna e só `/socket` e
`/webhooks` são públicos no Traefik ([doc 59 §3.1](59-deploy-dokploy-oci.md)); as chamadas do BFF
trazem um `x-forwarded-for` que o próprio BFF escreve, na rede interna, inalcançável de fora. O
custo aparece se qualquer rota passar a ser pública direto na API — aí as duas chaves de rate
limit por IP viram controláveis pelo cliente, do mesmo jeito da causa B do
[doc 68](68-bate-volta-rate-limit-global.md).

**O que o paga.** Escolher a profundidade do XFF em vez do primeiro item — contar da direita para a
esquerda o número de proxies confiáveis da topologia (é o que o `XFF_DEPTH` do adapter-node faz do
lado do BFF), e configurá-la junto com o proxy, como já é a regra para a lista de headers
confiáveis. Meia hora, mais uma decisão explícita sobre quantos hops confiar.

---

## D-17 · O branco sobre o sage está 2,71:1 — exceção de contraste aceita

**O que é.** Desde a [ADR-020](00-decisoes.md) `--mv-primary` é o sage da marca (`#7fa59a`) com
`--mv-on-primary: #ffffff`. O par mede **2,71:1**, abaixo do 4,5 de texto (WCAG 1.4.3) e abaixo até
do 3 de limite de componente (1.4.11). O `:hover` (`#72958b`) mede 3,29.

**Por que virou débito.** Decisão de produto, com o número na mesa: a alternativa conforme era texto
escuro sobre o mesmo sage (**6,56:1**, que é o que a landing já faz em `+page.svelte:538`), e foi
recusada por legibilidade percebida. Não é descuido nem furo de medição — é escolha registrada.

**O que custa hoje.** Alcança quase todo clique primário do app: `bg-primary` + `text-on-primary`
são os botões ([`Button.svelte:33`](../web/src/lib/components/Button.svelte)), o Toast e os chips de
grade de pacote — 86 usos dos tokens `primary*` no `web/src`. Some-se o colateral que a troca criou
e que **não foi resolvido**:

| uso | onde | claro | escuro |
| --- | --- | --- | --- |
| `text-primary` (link 11,5px) | `PatientHistory.svelte:121`, `PatientUpcoming.svelte:106` | **2,54–2,71** | 6,56–7,18 |
| `border-primary` | `PackageGradeModal`, `PackageCreateModal`, `pacientes/[id]:399` | **2,54–2,71** | 6,56–7,18 |
| `accent-primary` (checkbox) | `PackageCreateModal.svelte:453,472` | **2,71** | 7,18 |

Note a inversão do custo: no tema **escuro** esses três usos ficaram melhores do que precisam; quem
paga a conta é o tema **claro**.

Os três da tabela **não** foram pegos pela varredura axe — são condicionais e não renderizaram no
cenário que a spec semeia. Ou seja: o número real de nós reprovados em produção é **maior** que os 7
que o gate mediu. Quem for pagar este débito não deve tomar a lista do axe como completa.

**O que já foi pago junto com a troca**, e não conta como débito: o chip "próxima" da ficha
(`PatientUpcoming.svelte`) usava `primary` como texto sobre a própria tinta de 14% e caiu para
**2,26:1** — migrou para o par `teal-text`/`teal-subtle`. E o ícone do Toast, que sumia a 1,06:1,
passou a `text-on-primary`. Ambos estão descritos na ADR-020.

**O mesmo 2,71 no hover de `bg-accent`** (acrescentado em 2026-07-30, doc 93 §A-2). Dois botões
trocam para `hover:bg-accent` + `hover:text-white`:
[`notificacoes/+page.svelte:198`](../web/src/routes/(app)/notificacoes/+page.svelte) ("marcar como
lida") e [`AppointmentDrawer.svelte:809`](../web/src/lib/components/agenda/AppointmentDrawer.svelte).
Como `--mv-accent-solid` é o **mesmo** `#7fa59a` do `primary`, o número é o mesmo 2,71 — e a decisão
é a mesma da ADR-020, então entra aqui em vez de virar débito novo.

O estado **normal** desses dois passa com folga (`text-accent-text` sobre `bg-accent-subtle`,
5,30:1); é só o hover que reprova. Ele escapava por dois motivos independentes, e nenhum era
descuido: o axe varre o estado renderizado (ninguém está com o mouse sobre o botão durante a
varredura) e o filtro de isenção casava só `bg-primary`. Ou seja, o dia em que o axe passasse a
medir hover, a violação chegaria **sem isenção** e derrubaria o build sem dar à pessoa que caísse
ali o contexto deste débito. Se a saída 1 abaixo for escolhida, `--mv-accent-solid` precisa
escurecer junto — senão o hover fica reprovando sozinho.

**A isenção no gate do axe.** `e2e/a11y-interno.spec.ts` tinha 7 nós de `color-contrast` reprovando
em 5 telas, e o gate exige zero. A função `semExcecaoDoSage` filtra **só** os nós cujo HTML casa
`bg-primary` ou `bg-accent`; a regra `color-contrast` continua ativa em todo o resto. É a única
isenção do arquivo e some quando este débito for pago.

**O que o paga.** Duas saídas, e as duas já estão medidas:

1. **Escurecer o sage preservando a matiz** (calculado em OKLab): `#567b70` dá 4,71 com branco e
   4,58 sobre o canvas claro — conforme, e ainda claramente sage. `#597e73` (4,51) é o limite. Mexe
   só em `--mv-primary`/`--mv-primary-hover`; `--mv-sage` fica intacto para logo e landing.
2. **Voltar o texto para escuro** (`#16181c`, 6,56) — conforme e alinhado à landing, mas é
   exatamente o que a ADR-020 recusou.

Qualquer das duas fecha este débito. Ao fazer, apague o par de testes de exceção em
`web/src/lib/styles/contraste.test.ts` (eles avisam sozinhos quando o número passa de 4,5) e
restaure o piso normal na linha do `contraste-tokens.mjs`.

**Não confundir com o D-3**, que é a paleta categórica (avatar/tipo/prioridade) vivendo em duas
linguagens. Este aqui é um par único de token, e tem conserto de uma linha.

---

## D-18 · A borda do chip do acento está 1,83:1 — abaixo do piso de componente

**O que é.** `--mv-accent-border` mede **1,83:1** sobre `surface` no tema claro e **2,33:1** no
escuro (achatada sobre a superfície onde de fato pinta). O piso de limite de componente (WCAG
1.4.11) é **3**.

**Por que virou débito agora.** Não é regressão da [ADR-021](00-decisoes.md) — é o contrário: a
borda **melhorou** com a troca do teal para sage (era 1,64 no claro). O débito nasce porque a ADR
mexeu no valor e mediu, e medir o que já estava errado transforma um furo silencioso em item de
lista. O `contraste-tokens.mjs` já reportava essa linha como REPROVA; ninguém a tinha registrado.

**O que custa hoje.** 13 usos de `border-accent-border`, sempre **acompanhados** de
`bg-accent-subtle` e de texto em `accent-text`: o chip "Hoje" da navegação
([`AgendaNav.svelte:70`](../web/src/lib/components/agenda/AgendaNav.svelte)), o dia corrente no Mês e
na Semana, o botão de ação do drawer, o de marcar-como-lida em `/notificacoes`.

**Por que não é urgente.** A borda **não é o único indicador** desses elementos: o fundo tingido e o
texto (que mede 5,30 sobre o próprio chip) carregam o estado sozinhos. 1.4.11 fala de limite
*necessário para identificar* o componente — aqui ele não é. É por isso que isto é débito e não
correção imediata.

**O que o paga.** `#7fa59a` na matiz do sage precisa cair para cerca de **L 52%** para bater 3:1
sobre branco — algo como `#6f9a8e`, que é o próprio `accent-solid` escurecido e já mede 3,14. O
efeito colateral é que a borda passa a ter quase o mesmo tom do sólido, e o chip fica mais pesado
visualmente; vale checar no browser antes de fechar. Rodar `node scripts/contraste-tokens.mjs` para
confirmar — a linha `accent_border / surface` sai da lista de reprovas.
