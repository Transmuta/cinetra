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
