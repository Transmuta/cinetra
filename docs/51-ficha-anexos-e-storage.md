# 51 — A ficha do paciente: o que ficou fora do protótipo, e os anexos

> **Estado: CONSTRUÍDO** (2026-07-27). O doc nasceu como levantamento e virou o registro da fatia.
> A **§1** é a análise original da ficha contra o protótipo, agora com o estado de cada lacuna; a
> **§3** guarda as decisões que destravaram os anexos, e as **§4–§8** descrevem o que foi feito,
> o que foi achado ao construir e o que ainda depende de credencial do R2.

Duas perguntas, um doc. A **§1** compara a ficha construída com a do protótipo
([`Movimento.dc.html:2725-2830`](../interface/Movimento.dc.html#L2725)) e lista **tudo** que ficou
de fora do UI/UX, com evidência dos dois lados. A **§2 em diante** é a fatia de **anexos do
paciente** — não a tela, que é meia hora, mas o storage, a segurança e as decisões que a
bloqueavam.

**Método.** Li o `renderFicha` e o `anexosSection` do protótipo linha a linha contra
[`+page.svelte`](../web/src/routes/(app)/pacientes/%5Bid%5D/+page.svelte),
[`+page.server.ts`](../web/src/routes/(app)/pacientes/%5Bid%5D/+page.server.ts),
[`patients_controller.ex`](../api/lib/api_web/controllers/patients_controller.ex) e
[`patient.ex`](../api/lib/api/records/patient.ex). Nada aqui é estimado por leitura de doc: o que
digo que existe, existe no código citado.

---

## 1. A ficha hoje contra a ficha do protótipo

### 1.1 Conformidade, item a item

| # | Elemento do protótipo | Estado | Evidência |
| --- | --- | --- | --- |
| 1 | Voltar "‹ Pacientes" | ✅ fiel | [`:2741`](../interface/Movimento.dc.html#L2741) ↔ `+page.svelte:80` |
| 2 | Cabeçalho: avatar, nome, nome social, CPF, pílula de convênio, selo de contato | ✅ fiel | [`:2744-2753`](../interface/Movimento.dc.html#L2744) ↔ `:101-123` |
| 3 | Botão **"Agendar"** no cabeçalho | ❌ **ausente** | [`:2756`](../interface/Movimento.dc.html#L2756) |
| 4 | Botão "Editar dados" | ✅ fiel | [`:2757`](../interface/Movimento.dc.html#L2757) ↔ `:136-141` |
| 5 | Chips de tags | ✅ fiel | [`:2760`](../interface/Movimento.dc.html#L2760) ↔ `:146-152` |
| 6 | Stat **Faltas** | ❌ **ausente** (trocado por "Comunicação") | [`:2763`](../interface/Movimento.dc.html#L2763) ↔ `:161-163` |
| 7 | Stats Idade e Consentimento LGPD | ✅ fiel (e melhor, ver §1.3) | [`:2762,2764`](../interface/Movimento.dc.html#L2762) |
| 8 | Layout de **duas colunas** (60/40) | ❌ **divergente** — hoje é 2×N empilhado | [`:2768-2827`](../interface/Movimento.dc.html#L2768) ↔ `:168-258` |
| 9 | Cartões Contato / Identificação / Emergência / Atendimento & convênio / Consentimentos | ✅ fiéis | [`:2770-2808`](../interface/Movimento.dc.html#L2770) ↔ `:173-246` |
| 10 | Cartão **Pacotes** | ✅ existe, ⚠️ cabeçalho fora do padrão | [`:416-455`](../interface/Movimento.dc.html#L416) ↔ [`PackageList.svelte:47-63`](../web/src/lib/components/patients/PackageList.svelte#L47) |
| 11 | Cartão **Histórico de atendimentos** | ✅ existe, ⚠️ cabeçalho e linha divergentes | [`:2814-2824`](../interface/Movimento.dc.html#L2814) ↔ [`PatientHistory.svelte`](../web/src/lib/components/patients/PatientHistory.svelte) |
| 12 | Cartão **Anexos e documentos** | ❌ **ausente inteiro** | [`:962-989`](../interface/Movimento.dc.html#L962), chamado em [`:2826`](../interface/Movimento.dc.html#L2826) |

### 1.2 As lacunas, uma a uma

**L1 · Anexos e documentos — o cartão inteiro não existe.**
É a maior. O protótipo tem drop-zone com drag-and-drop, `accept="image/*,application/pdf"`,
múltiplos arquivos, contagem ("3 arquivos"), miniatura da imagem / ícone de PDF, nome, tipo,
tamanho formatado, data, "Abrir" em nova aba e "Remover"
([`:962-989`](../interface/Movimento.dc.html#L962)). Do nosso lado não há nem placeholder — a
ausência está **declarada** em três pontos:
[`+page.server.ts:20-21`](../web/src/routes/(app)/pacientes/%5Bid%5D/+page.server.ts#L20)
("Anexos seguem fora: dependem do prontuário, v2"),
[`patients_controller.ex:13-14`](../api/lib/api_web/controllers/patients_controller.ex#L13) e
[`35 §Frente 7`](35-plano-execucao-backlog.md). É **omissão deliberada**, não esquecimento — e o
que a destrava é a §3 deste doc, não trabalho de tela.

**L2 · O botão "Agendar" sumiu do cabeçalho.**
No protótipo, a ficha é ponto de partida de agendamento: `openModal('novoAgendamento', {patientId,
date})` ([`:2756`](../interface/Movimento.dc.html#L2756)). Hoje o caminho só existe **ao contrário**
— o drawer da agenda leva à ficha
([`AppointmentDrawer.svelte:340`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L340)),
a ficha não leva à agenda. Quem atende ao telefone abre a ficha, confirma o convênio e precisa
navegar até a agenda e buscar o paciente de novo. **Custo baixo de conserto** (o modal de
agendamento já aceita `patientId` pré-selecionado, é o mesmo caminho do "Novo pacote"), **ganho
alto de fluxo**. É a lacuna com melhor razão custo/benefício da lista.

**L3 · O stat "Faltas" — o dado existe, o JSON não o carrega.**
`count :faltas` está no recurso, filtrando `:faltou` **não justificada**
([`patient.ex:281-283`](../api/lib/api/records/patient.ex#L281)), e já é servido para a agenda
([`agenda_json.ex:42`](../api/lib/api_web/agenda_json.ex#L42)) e para a fila. Mas
`patient_json/1` não o inclui ([`patients_controller.ex:157-196`](../api/lib/api_web/controllers/patients_controller.ex#L157)),
então a ficha — a tela onde a pergunta "esse paciente falta?" mais importa — é a única que não
mostra. O comentário do doc 35 ("`faltas` depende de F1") **envelheceu**: F1 foi feita. Conserto:
`load: [:faltas]` na leitura + uma chave no JSON + trocar o terceiro stat. O stat "Comunicação"
que ocupa o lugar é redundante — o mesmo dado já aparece como selo no cabeçalho (`:117-121`) e como
linha no cartão de consentimentos (`:236-243`), três vezes na mesma tela.

**L4 · O layout de duas colunas virou empilhamento.**
Protótipo: coluna esquerda `flex: 1.5 1 340px` com os cinco cartões cadastrais, coluna direita
`flex: 1 1 300px` com Pacotes, Histórico e Anexos
([`:2768-2827`](../interface/Movimento.dc.html#L2768)). O cadastro (estático, consultado) e a
atividade (dinâmica, o que se olha primeiro) ficam lado a lado. Hoje: `grid md:grid-cols-2` para os
cinco cartões, e Pacotes/Histórico **largura cheia abaixo** (`:168`, `:250`, `:258`). Duas
consequências: (a) os cartões cadastrais fluem na ordem de leitura, deixando **um buraco** na
segunda coluna da terceira linha (são cinco cartões em grade de dois); (b) em 1440px, Pacotes ocupa
1180px de largura para mostrar uma barra de progresso — e o Histórico exige rolagem para aparecer,
quando no protótipo estava na dobra.

**L5 · Pacotes e Histórico não usam o cabeçalho de cartão da própria página.**
Todo cartão da ficha usa o `cardHead`: quadrado 30×30 arredondado, fundo teal-subtle, ícone teal,
título 14px bold ([`:2735`](../interface/Movimento.dc.html#L2735)) — e a implementação é fiel nisso
para os cinco cadastrais (`+page.svelte:56-67`). Já `PackageList` e `PatientHistory` usam outro
padrão: ícone cinza solto + título 13px **maiúsculo com tracking**
([`PackageList.svelte:50-53`](../web/src/lib/components/patients/PackageList.svelte#L50),
[`PatientHistory.svelte:34-37`](../web/src/lib/components/patients/PatientHistory.svelte#L34)). Não
é divergência com o protótipo apenas — é **inconsistência dentro da mesma tela**, dois idiomas de
cabeçalho a 300px de distância.

**L6 · O Histórico perdeu a contagem e a moldura.**
Protótipo: contagem em mono no canto direito do cabeçalho
([`:2815`](../interface/Movimento.dc.html#L2815)) e as linhas dentro de uma caixa com borda e
`overflow: hidden` ([`:2816`](../interface/Movimento.dc.html#L2816)), com a data em coluna mono de
largura fixa (78px). Hoje: sem contagem, sem moldura, data em largura variável — as datas não
alinham entre linhas, que é justamente o que a coluna fixa resolvia.

**L7 · "há mais no histórico" é um beco.**
`PatientHistory` avisa que o servidor cortou a lista
([`:80-84`](../web/src/lib/components/patients/PatientHistory.svelte#L80)) mas não oferece como ver
o resto — sem "carregar mais", sem link para uma busca filtrada. Honesto (melhor que mentir), porém
inacabado: para um paciente de pacote longo, o começo do tratamento fica inalcançável pela ficha.

### 1.3 O que o código faz **melhor** — não "consertar" de volta

Três divergências são deliberadas e certas; registro para ninguém as tratar como bug de fidelidade:

- **Arquivar / reativar.** Não existe no protótipo. A implementação tem o botão, a tarja de
  arquivado e a ação de reativar (`+page.svelte:84-98`, `:126-135`), coerente com o
  soft-delete que é regra do projeto ([`50 §D-1`](50-debitos-tecnicos.md)).
- **Consentimento LGPD honesto.** O protótipo **fixa** `'OK'` em verde
  ([`:2764`](../interface/Movimento.dc.html#L2764)) mesmo sem consentimento. A implementação lê
  `p.lgpd` e mostra "Pendente" quando é o caso (`:162`). Mentir sobre consentimento é exatamente o
  que não se pode fazer numa tela de LGPD.
- **Selo de pacote e cor do tipo no histórico.** A linha ganhou bolinha de cor e chip "pacote"
  (`PatientHistory.svelte:46-60`), que o protótipo não tinha, e o selo sai da **presença** e não do
  bloco ([`41`](41-turma-presenca-por-participante.md)) — numa turma, o bloco concluído com a
  presença faltando contaria uma sessão que o paciente não fez.

### 1.4 O que foi feito

| Lacuna | Estado | Onde |
| --- | --- | --- |
| **L1** Anexos | ✅ **construída** | §4–§6 deste doc |
| **L2** Agendar no cabeçalho | ✅ feito | ficha → `/agenda?paciente=<id>` abre o modal com o paciente já escolhido (`+page.svelte`, `NewAppointmentModal.pacientesIniciais`) |
| **L3** Stat Faltas | ✅ feito | `load: [:faltas]` em `fetch_clinic_patient/2` + `faltas/1` no `patient_json`; substitui "Comunicação", que era o terceiro lugar da mesma tela a dizer a mesma coisa |
| **L4** Duas colunas | ✅ feito | `flex-[1.5_1_340px]` (cadastro) + `flex-[1_1_300px]` (atividade), como o protótipo |
| **L5** Cabeçalhos unificados | ✅ feito | `PackageList` e `PatientHistory` passaram ao `cardHead` teal dos cartões vizinhos |
| **L6** Contagem + moldura do histórico | ✅ feito | contagem em mono no cabeçalho, linhas dentro da caixa com borda, data em coluna de largura fixa |
| **L7** Paginação do histórico | ⬜ **fica** | segue com o aviso honesto ("há mais no histórico"); paginar exige API + tela e o volume ainda não cobra |

Só o **L7** ficou de fora, e por escolha: o aviso não mente, e o ganho hoje é pequeno.

---

## 2. Anexos: o que o protótipo faz, e por que quase nada disso serve

O `addAnexos` ([`:954-960`](../interface/Movimento.dc.html#L954)) é um mock honesto de mock:

```js
url: URL.createObjectURL(f)   // blob: efêmero, morre ao fechar a aba
```

Tudo vive em `this.state.anexos[pid]` — memória do browser. **Nada** persiste, nada sai da máquina,
nada é validado. O filtro de tipo confia no `f.type` **declarado pelo cliente**
([`:955`](../interface/Movimento.dc.html#L955)); o "até 10 MB" é texto na tela
([`:976`](../interface/Movimento.dc.html#L976)) sem nenhuma checagem; o `fmtBytes`
([`:953`](../interface/Movimento.dc.html#L953)) só formata para exibir.

O que **se aproveita** do protótipo é o desenho de interação, que é bom: drop-zone com estado de
drag, lista compacta com miniatura, tamanho e data, abrir em nova aba, remover. O que **não** se
aproveita é qualquer linha da mecânica. E é preciso dizer o tamanho real do que falta: um anexo
aqui é **laudo, exame de imagem, receita** — LGPD **Art. 11**, categoria especial
([`06 §1.2`](06-seguranca-e-lgpd.md)). O protótipo trata como se fosse foto de perfil.

---


## 3. As decisões que destravaram a fatia

Quatro perguntas bloqueavam qualquer linha de código. Todas respondidas em **2026-07-27**, com o
custo de cada escolha na mesa.

| # | Pergunta | Decisão | O que ela custa |
| --- | --- | --- | --- |
| **B1** | Anexo entra na v1? O ADR-013 o listava **nominalmente** entre os adiados | **Sim** — emenda ao ADR-013. `Attachment` sai do v2; `ClinicalTag` e `Consent` versionado ficam | Aceitar LGPD Art. 11 na v1. Não há meio-termo: quem abre campo de upload recebe laudo, e um recorte "só administrativo" seria ilusão |
| **B2** | Quem vê um anexo? | **Owner, admin e recepção** — para tudo. O `profissional` **não** vê | O fisioterapeuta que atende não abre o laudo do próprio paciente pelo sistema. Escolha explícita de quem decide o produto; a lista está em `Api.Records.Attachment.papeis/0`, e virar a chave é uma linha |
| **B3** | Antivírus na v1? | **Não** — débito declarado ([`50 §D-6`](50-debitos-tecnicos.md)) | Um PDF com payload malicioso passa. Ficam no lugar: allowlist fechada sem SVG, magic bytes conferidos no servidor, e o arquivo nunca renderizado na origem do app |
| **B4** | Provedor e região | **Cloudflare R2**, bucket privado (ADR-008) | O R2 não tem região no Brasil. A transferência internacional precisa do amparo do Art. 33 da LGPD (cláusulas contratuais do DPA da Cloudflare) — **fica registrado como ponto a confirmar com o jurídico**, não resolvido aqui |

Mais o que veio junto com o pedido do produto: **50 MB por arquivo**, **PDF e imagem**, **um por
vez** (vários de uma vez é evolução prevista), **poder renomear**, e **acesso temporário no clique**
para baixar ou visualizar.

E uma quinta, que a §4 explica: **remover apaga de verdade** — linha e bytes —, e não soft-delete.

---

## 4. O que foi construído

### 4.1 O fluxo, e por que cada ordem é uma garantia

```
browser              BFF (Node)        API (Elixir)              R2
  │ 1. POST /anexos ────►  ────────────►  valida o declarado, cria a
  │                                       linha :pendente, assina o PUT
  │ ◄──────────────────────────────────── {attachment, upload}
  │ 2. PUT (XHR, com barra de progresso) ──────────────────────────►
  │ 3. POST /anexos/:id ─►  ────────────►  HEAD (tamanho real)
  │                                        GET range 0-15 (magic bytes)
  │                                        confere → :disponivel
  │                                        ou apaga objeto + linha
```

Três ordens que não são estilo:

1. **A linha nasce antes dos bytes.** Assim "objeto sem linha" — laudo invisível ao sistema, fora
   de qualquer policy — deixa de ser possível. Sobra linha-sem-objeto (aba fechada no meio), que é
   visível por consulta e recolhida por `Api.Housekeeping.PruneAttachments`. É o erro barato.
2. **A remoção apaga o objeto primeiro, a linha depois.** Invertida, uma falha no meio produziria
   de novo o órfão caro. Como está, o pior caso é linha viva apontando para nada: o download dá
   404, o usuário repete, e o `DELETE` do R2 é idempotente.
3. **A autorização vem antes de tocar no bucket.** Ver §7 — foi um bug de verdade.

Os bytes **não passam** pelo Node nem pelo BEAM
([`05 §5.5`](05-observabilidade-e-producao.md)). O que trafega pelo BFF é metadado e URL assinada.

### 4.2 Backend (`api/`)

| Módulo | Papel |
| --- | --- |
| [`Api.Storage`](../api/lib/api/storage.ex) | A porta: cinco operações e **nenhuma `list`** — o desenho torna o órfão de objeto impossível em vez de o caçar |
| [`Api.Storage.SigV4`](../api/lib/api/storage/sig_v4.ex) | Assinatura por query string. **Zero dependência nova** além do `req` que já estava na árvore: dispensou `ex_aws` + `ex_aws_s3` + `sweet_xml` + `hackney` |
| [`Api.Storage.R2`](../api/lib/api/storage/r2.ex) | Adaptador do Cloudflare R2 |
| `Api.Storage.Memory` (`test/support/`) | O storage da suíte — sem rede, sem credencial, sem Cloudflare de pé |
| [`Api.Records.Attachment`](../api/lib/api/records/attachment.ex) | O recurso: tenancy por atributo, RLS, policy única com `@papeis` |
| [`…Attachment.Conteudo`](../api/lib/api/records/attachment/conteudo.ex) | Allowlist, tetos, magic bytes, chave do objeto. Puro |
| [`Api.Records.AttachmentEvent`](../api/lib/api/records/attachment_event.ex) | A trilha: uma linha por **toque**, inclusive `:visualizou` |
| [`Api.Housekeeping.PruneAttachments`](../api/lib/api/housekeeping/prune_attachments.ex) | Poda de upload abandonado (com os bytes) e de trilha antiga |
| [`ApiWeb.AttachmentsController`](../api/lib/api_web/controllers/attachments_controller.ex) | Cinco rotas; nenhum byte de laudo atravessa |

**A trilha é tabela própria, não `AshPaperTrail`.** O PaperTrail registra escritas, e a pergunta da
LGPD sobre anexo é *"quem **leu** o laudo?"* — leitura não gera versão. Os docs cobram isso duas
vezes ([`05 §5.5`](05-observabilidade-e-producao.md), [`06 §7.2`](06-seguranca-e-lgpd.md)) e o
PaperTrail simplesmente não responde. `attachment_events` responde às duas de uma vez, e grava o
`:visualizou` no instante em que a **URL assinada é emitida** — que é quando o acesso passa a
existir. Só `clinic_id` tem FK: o registro precisa sobreviver ao que ele registra.

**As FKs de `attachments` são `RESTRICT`, contra o padrão da casa.** Todo filho de `clinics` no
projeto é `CASCADE`; aqui não, e nem para `patients`. Um `CASCADE` apaga a **linha** dentro do
Postgres, sem passar pela aplicação — logo sem o `Api.Storage.delete/1` que tira o objeto do
bucket. Sobraria laudo no R2 sem nada apontando para ele. `RESTRICT` vira isso numa trava: apagar
paciente ou clínica **obriga** a passar pela aplicação. É a ordem que o F8
([`50 §D-1`](50-debitos-tecnicos.md)) terá de respeitar, e `on_delete_test.exs` já a vigia.

### 4.3 Frontend (`web/`)

[`PatientAttachments.svelte`](../web/src/lib/components/patients/PatientAttachments.svelte) reproduz
a interação do protótipo (drop-zone com estado de drag, lista compacta, abrir, remover) sobre a
mecânica nova, mais o que o protótipo não tinha: **renomear**, **barra de progresso** e os estados
de erro. O upload usa `XMLHttpRequest` e não `fetch` por um motivo só — `fetch` não expõe progresso
de upload, e um laudo de 40 MB numa conexão de clínica deixaria a barra parada por dezenas de
segundos.

**Miniatura ficou de fora, por decisão.** Bucket privado significa que toda miniatura precisaria de
uma URL assinada gerada ao carregar a página — e como cada emissão é auditada, abrir a ficha de um
paciente com 8 fotos geraria 8 linhas de "acesso a dado de saúde" sem ninguém ter clicado em nada.
Ícone na lista, arquivo em aba nova.

**A CSP ganhou uma terceira exceção ao ADR-005.** O `PUT` vai direto ao bucket, então a origem do R2
entra no `connect-src` — derivada do `R2_ACCOUNT_ID`, e não de uma variável própria, porque duas
variáveis para o mesmo endereço são duas chances de divergirem. Como a CSP é **build-time**, ela vem
por `ARG` no `Dockerfile.prod` e `[build.args]` no `fly.toml`, nunca por `[env]` — o mesmo footgun
que a Onda 5 documentou.

---

## 5. Segurança: o §7 do doc 06, item a item

| Requisito ([`06 §7`](06-seguranca-e-lgpd.md)) | Estado |
| --- | --- |
| 1. Storage privado, nunca público | ✅ bucket privado; a `chave` nem sai no JSON |
| 2. URL assinada de vida curta + acesso auditado | ✅ 5 min no `GET`, 10 no `PUT`; `:visualizou` gravado na emissão |
| 3. Upload não confia na extensão | ✅ magic bytes lidos **do bucket**, e comparados com o tipo declarado |
| 4. Antivírus | ❌ **débito declarado** ([`50 §D-6`](50-debitos-tecnicos.md)) |
| 5. Limite de tamanho no servidor | ✅ três camadas: antes de assinar, no `content-length` **assinado**, e no `HEAD` |
| 6. `Content-Disposition` | ⚠️ **`inline`, divergência deliberada** — ver abaixo |

**Sobre o `inline`.** O §7.6 pede `attachment`, e o que o tornava obrigatório era *"sem permitir
execução inline **no contexto do app**"*. Esse contexto não existe: os bytes saem de
`*.r2.cloudflarestorage.com`, origem diferente, em aba separada — um PDF malicioso renderizado ali
não alcança sessão, cookie nem DOM nossos. Somem-se a allowlist fechada (sem SVG), os magic bytes,
e o fato de o `response-content-type` da URL ser o tipo **farejado**, não o declarado. Forçar
download para ver uma radiografia seria fricção diária sem ganho.

E os cinco que o doc 06 não lista, resolvidos aqui: **SVG fora da allowlist**; **cota de 100 anexos
por paciente**, contando os `:pendente` (é por eles que o abuso passaria); **chave derivada de ids,
nunca do nome do arquivo** (`laudo-ressonancia-joelho.pdf` *é* o dado sensível); **poda de upload
abandonado**; e **nenhum órfão de objeto por construção**.

Fica aberto: **rate limit no `presign`** — o `Api.RateLimiter` hoje só cobre auth, e emitir URL
assinada é operação barata que gera custo caro.

---

## 6. Testes

**Backend: 1158 testes, 0 falhas, 90,8%** (gate `mix coveralls`, mínimo 80).

O que se afirma, e não é óbvio:

- **o `profissional` não passa em porta nenhuma** — inclusive na leitura, e inclusive chamando o
  domínio direto, sem o controller;
- **paciente e anexo de outra clínica são indistinguíveis de inexistentes** (404, não 403);
- **JPEG declarado como PDF é recusado e descartado** — objeto apagado, linha destruída;
- **a cota conta os pendentes**;
- **remover apaga os bytes**, e a poda de pendente também;
- **anexo confirmado nunca é podado**, por mais velho que seja — poda é lixo de upload, não
  retenção de prontuário;
- **a assinatura SigV4 é determinística e está fixada num vetor de regressão** — o que ele **não**
  prova é interoperabilidade com o R2; essa só o serviço real prova (§8).

**Web:** `PatientAttachments` e `$lib/attachments` cobertos (estados da seção, abrir/renomear/
remover, o `accept` sem curinga), `svelte-check` limpo.

---

## 7. Dois achados de construir

**7a. A ordem "objeto primeiro" apagava bytes de quem não podia apagar.**
`delete_attachment/2` fazia `Api.Storage.delete` e só então o `destroy`, onde a policy roda. Um
`profissional` chamando o domínio direto **não removia a linha** — e já tinha apagado o laudo. Pego
pelo teste de defesa em profundidade, não pela tela (a guarda do controller o barrava antes).
Consertado com `autorizar/3` na frente de **todo** efeito colateral no bucket; `confirm_attachment/2`
tinha a mesma forma pelo caminho de erro e foi corrigida junto.

**7b. Sem credencial de R2, a tela oferecia o upload.**
`Api.Storage.configured?/0` existia justamente para evitar isso, mas só era consultada no `start` —
a **lista** respondia 200 com os limites, a drop-zone aparecia, e o 503 só chegava depois de o
usuário escolher o arquivo. Invisível à suíte: nela o storage está sempre configurado (é o
adaptador de memória). Pego na verificação ao vivo. Agora `limites` vem `nil` sem credencial e a
seção diz o que houve. **É a mesma lição do doc 49**: regra que atravessa a fronteira precisa de
teste que atravesse a fronteira — e de olhar a tela.

---

## 8. O que falta

**Verificação ao vivo, feita:** layout de duas colunas, "Agendar" abrindo o modal com o paciente já
escolhido, stat de faltas, cabeçalhos unificados, e a degradação sem credencial. Console limpo.

**Verificação ao vivo, pendente:** o ciclo real contra o R2 — `PUT` assinado, conferência de magic
bytes sobre bytes que vieram do bucket, abrir em aba nova, renomear e remover. Depende de:

1. as quatro variáveis no `.env` (modelo em [`.env.example`](../.env.example));
2. **CORS no bucket** — sem ele o `PUT` do browser é bloqueado pelo preflight:

   ```json
   [{"AllowedOrigins":["http://localhost:5173"],
     "AllowedMethods":["PUT"],
     "AllowedHeaders":["content-type"],
     "MaxAgeSeconds":3600}]
   ```

3. em produção, `R2_ACCOUNT_ID` também como `[build.args]` do `web/fly.toml` (a CSP é build-time).

**Aberto para decisão humana:** a jurisdição do R2 (B4) — não há região no Brasil, e o amparo do
Art. 33 precisa ser confirmado antes do primeiro laudo real.

**Fica para depois:** rate limit no `presign` (§5), antivírus ([`50 §D-6`](50-debitos-tecnicos.md)),
upload de vários arquivos de uma vez, e a paginação do histórico (L7).

---

## Referências

- Protótipo: [`renderFicha`](../interface/Movimento.dc.html#L2725),
  [`anexosSection`](../interface/Movimento.dc.html#L962),
  [`addAnexos`](../interface/Movimento.dc.html#L954)
- [`00 §ADR-007/008/013`](00-decisoes.md) — dado de saúde, deploy/storage, prontuário é v2
  (**ADR-013 emendado por este doc**: `Attachment` sai do v2)
- [`05 §5.5`](05-observabilidade-e-producao.md) — object storage e URL assinada
- [`06 §1.2, §7`](06-seguranca-e-lgpd.md) — anexos como PII sensível; os seis requisitos
- [`08 §GAP-11`](08-roadmap.md) — anexos sem proteção → storage privado
- [`35 §Frente 7`](35-plano-execucao-backlog.md) — por que a ficha saiu parcial
- [`50 §D-1, §D-6`](50-debitos-tecnicos.md) — retenção; antivírus
