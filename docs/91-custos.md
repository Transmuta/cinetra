# 91 — Custos: o piso fixo, o que escala com o uso, e o que ainda não está na conta

A lista de custos existia como anotação solta, com **três moedas** (US$, R$), **três cadências**
(mês, ano, unidade) e **duas naturezas** (operar o produto vs. construí-lo) misturadas na mesma
enumeração. Este documento reorganiza a mesma informação em quatro perguntas que dão respostas
diferentes:

1. **Qual o piso** — o que sai da conta mesmo com zero clínica usando (§2).
2. **O que escala, e com o quê** — qual driver puxa cada centavo (§3).
3. **Quanto custa uma clínica** — o cenário fechado, e como a conta anda com N clínicas (§4, §5).
4. **O que ainda não está na lista** — os buracos, que aqui são maiores que qualquer linha da
   lista original (§6, §7).

> ~~**A divergência que vem primeiro, porque muda o número:**~~ **RESOLVIDA em 2026-07-31 — o
> KVM 2 fica.** A divergência era esta: a lista trazia **KVM 2 (8 GB) por R$ 108,99/mês** e o
> [doc 87 §2](87-servidor-hostinger-riscos-e-cuidados.md) concluía, com a conta escrita container a
> container, que "8 GB não cabe" e que "16 GB (KVM 4) é o piso".
>
> **O servidor foi provisionado e a conta do doc 87 estava errada.** Com prod + HML +
> observabilidade + Dokploy no ar ao mesmo tempo, o consumo residente medido é **≈ 3,5 GB**, não
> 8,5–12 GB — a estimativa somava `mem_limit` (**teto** de container) como se fosse consumo, e
> errou por ~3× para cima. Ver
> [doc 87 §2.1](87-servidor-hostinger-riscos-e-cuidados.md#21-o-que-a-máquina-de-verdade-mediu-2026-07-31--a-estimativa-acima-estava-errada).
>
> **Consequência para este documento:** vale a **linha do KVM 2** nas tabelas abaixo (piso de
> **R$ 135,08/mês**), a linha do KVM 4 fica como cenário de crescimento, e **nenhum** dos três
> cortes precisou entrar. Decisão travada no [ADR-023](00-decisoes.md).
>
> **O que ainda não foi medido**, e é o que reabriria a conta: consumo sob carga real de clínica.
> Os 3,5 GB são um ponto com pouca ou nenhuma gente usando ([D-21](50-debitos-tecnicos.md)).

---

## 1. Premissas declaradas

Números em moeda estrangeira só viram real por cima de premissas. Elas ficam **aqui, em um lugar
só**, para que atualizar a conta seja trocar uma linha e não caçar valores pelo texto.

| Premissa | Valor adotado | Observação |
|---|---|---|
| Câmbio | **US$ 1 = R$ 5,50** | Parâmetro. Toda conversão do doc sai daqui. |
| IOF sobre cartão internacional | **3,5%** | Serviço cobrado em dólar no cartão chega **3,5% mais caro** que o câmbio puro. Confirmar a alíquota vigente. |
| **Dólar efetivo** (câmbio + IOF) | **R$ 5,69** | É este que usei nas linhas em US$, não os R$ 5,50. |
| Clínica típica | 4 profissionais, **500 atendimentos/mês** | Base do cenário do §4. Ajuste e o §4 inteiro se recalcula. |

Serviços cobrados **em real** (Hostinger, Registro.br, mensagem da Zernio) não levam IOF.

---

## 2. O piso: o que sai da conta com zero clínica

Custo que existe pelo simples fato de o produto estar no ar.

| Item | Fornecedor | Preço de lista | **R$/mês** |
|---|---|---|---|
| Servidor — **KVM 2 (8 GB)** ✅ *(provisionado, em uso — 3,5 GB de 8 com tudo no ar)* | Hostinger | R$ 108,99/mês | **108,99** |
| Servidor — **KVM 4 (16 GB)** *(cenário de crescimento, não contratado)* | Hostinger | *a confirmar no painel* | **≈ 220,00** ⚠️ |
| Domínio | Registro.br | R$ 40/ano | **3,33** |
| Número de WhatsApp | Zernio + Meta | US$ 4/mês | **22,76** |
| Armazenamento de arquivos | Cloudflare R2 | US$ 0,015/GB/mês | **0,00** (franquia) |
| E-mail transacional | Resend | US$ 0,90/1.000 | **0,00** (franquia) |
| TLS | Let's Encrypt via Traefik | — | **0,00** |
| Observabilidade | Loki/Grafana/Prometheus **self-hosted** | — | **0,00** em licença; o custo dela é **RAM**, e está embutido no plano do servidor |
| **Piso com KVM 2** ✅ *(o vigente)* | | | **R$ 135,08/mês** · R$ 1.621/ano |
| **Piso com KVM 4** *(hipótese de crescimento)* | | | **≈ R$ 246,09/mês** · ≈ R$ 2.953/ano |

⚠️ **O preço do KVM 4 é estimativa minha, não valor verificado** — trate como campo a preencher, não
como número. É a única linha da tabela que não veio de fonte confirmada. Como o KVM 2 ficou
([ADR-023](00-decisoes.md)), essa lacuna deixou de bloquear a conta: **o piso vigente é o de cima,
R$ 135,08/mês**, e todos os números derivados deste documento saem dele.

Duas observações que a lista original escondia ao escrever "$4/mês pelo número":

- **O número pode não ser piso — pode ser custo por clínica.** Se cada clínica tiver o próprio
  número de WhatsApp (que é o normal, o paciente reconhece o número da clínica), esses US$ 4 saem do
  §2 e viram linha do §3, multiplicando por N. O §5 assume esse caso. **É a pergunta de maior
  impacto financeiro da lista inteira** (§7, Q1).
- **Registro.br não é assinatura mensal.** R$ 40/ano é uma cobrança única anual — o R$ 3,33 é
  rateio contábil, não uma cobrança que aparece todo mês na fatura.

---

## 3. O que escala, e com qual driver

Cada linha responde "sobe quando **o quê** sobe?". É o que separa custo que você controla via preço
do produto de custo que você controla via engenharia.

| Recurso | Driver real | Preço unitário | Em R$ |
|---|---|---|---|
| **Mensagem WhatsApp** | atendimento agendado (lembrete) + resposta do paciente | R$ 0,05 por mensagem **enviada ou recebida** | R$ 0,05 |
| **E-mail** | login por magic link, convite de membro, e-mail ao paciente | US$ 0,90/1.000 | R$ 0,0051 |
| **Armazenamento** | anexo na ficha do paciente (GB acumulado, **não** apagado) | US$ 0,015/GB/mês | R$ 0,085/GB |
| **Operações no R2** | upload e download de anexo | Classe A ≈ US$ 4,50/M · Classe B ≈ US$ 0,36/M | ruído em qualquer volume nosso |
| **Egress do R2** | download de anexo | **US$ 0 — o R2 não cobra saída** | R$ 0 |

Três coisas que essa tabela deixa ver e a lista linear não deixava:

1. **A mensagem de WhatsApp é o único custo variável que importa.** No cenário do §4 ela é **99,7%**
   da variável. E-mail e storage, no volume de uma clínica, custam **centavos** — literalmente.
2. **Storage é o único que acumula.** Mensagem e e-mail são gasto do mês e somem; anexo entra e fica
   pagando aluguel todo mês, para sempre, até alguém apagar. É o custo que cresce sozinho sem
   ninguém usar mais o sistema. A retenção (`housekeeping/`) é, além de LGPD, uma alavanca de custo.
3. **Egress zero é o motivo de o R2 estar aqui** em vez de S3. Anexo de ficha é escrito uma vez e
   lido muitas; num provedor que cobra saída, o download dominaria a conta. Aqui ele é grátis.

### As franquias, que zeram as duas linhas pequenas

| Serviço | Franquia | Quando o cenário do §4 encosta nela |
|---|---|---|
| **Resend** | 3.000 e-mails/mês (100/dia) | ~20 clínicas ativas |
| **R2** | 10 GB armazenados/mês | ~10 clínicas, ao ritmo de 1 GB cada — **e mais cedo a cada mês**, porque anexo acumula |

Ou seja: **até algo entre 10 e 20 clínicas, e-mail e armazenamento custam literalmente R$ 0.** Vale
saber para não gastar engenharia otimizando o que ainda não é cobrado — e para saber onde a conta
muda de forma quando passar disso.

---

## 4. Cenário fechado: uma clínica típica

4 profissionais, **500 atendimentos/mês**:

| Recurso | Volume estimado | Conta | R$/mês |
|---|---|---|---|
| WhatsApp | 500 lembretes + ~150 respostas = **650 mensagens** | 650 × R$ 0,05 | **32,50** |
| E-mail | ~150 (logins + convites + e-mails ao paciente) | dentro da franquia | **0,00** *(seria R$ 0,77)* |
| Armazenamento | ~1 GB de anexos | dentro da franquia | **0,00** *(seria R$ 0,09)* |
| **Variável por clínica** | | | **R$ 32,50** |
| **Custo por atendimento** | | R$ 32,50 ÷ 500 | **R$ 0,065** |

**Seis centavos e meio por atendimento.** É esse o número para levar a qualquer conversa de preço —
não os R$ 108,99 do servidor, que são piso e não escalam com uso.

O lembrete só existe onde a clínica **configurou** `msg_lembrete_horas` — que nasce `nil`
([`reminder_job.ex`](../api/lib/api/messaging/reminder_job.ex)). Clínica sem número configurado é
pulada, e **seu custo variável de WhatsApp é zero**. A tabela acima é o teto de uma clínica que usa
tudo, não a média.

---

## 5. Como a conta anda com N clínicas

Assumindo **um número de WhatsApp por clínica** (R$ 22,76/mês cada) e o servidor **KVM 4**
(R$ 223,33/mês de fixo compartilhado, servidor + domínio):

| Clínicas | Fixo compartilhado | Por clínica (número + variável) | **Total/mês** | **Custo por clínica** |
|---|---|---|---|---|
| 1 | R$ 223,33 | R$ 55,26 | **R$ 278,59** | **R$ 278,59** |
| 5 | R$ 223,33 | R$ 276,30 | **R$ 499,63** | **R$ 99,93** |
| 10 | R$ 223,33 | R$ 552,60 | **R$ 775,93** | **R$ 77,59** |
| 25 | R$ 223,33 | R$ 1.381,50 | **R$ 1.604,83** | **R$ 64,19** ⚠️ |

O formato da curva é o que importa: **o custo por clínica cai rápido até ~10 e depois quase para**,
porque a partir dali a conta é dominada por custo marginal (R$ 55,26), não por diluição do fixo. O
piso assintótico é **R$ 55/clínica/mês** — e **R$ 22,76 desses 55 são o número de WhatsApp**, o que
faz da Q1 do §7 a pergunta mais cara da lista.

⚠️ **A linha de 25 clínicas não é confiável sem revisitar o servidor.** Nenhuma das tabelas modela
crescimento de CPU/RAM/disco com carga, e o doc 87 mostra que o dimensionamento é apertado já no
caso vazio. A conta assume "o mesmo servidor aguenta", o que é premissa, não medição.

---

## 6. O que **não** está na lista

Estes não estão precificados em lugar nenhum e são, somados, provavelmente maiores que a lista toda.

| Buraco | Por que importa | Ordem de grandeza |
|---|---|---|
| **Tarifa de template da Meta** | Os R$ 0,05 da Zernio podem ser **só a Zernio**; a Meta cobra por template de utilidade/marketing por fora. Se for por fora, o custo variável dominante do §4 está **subestimado**. | pode dobrar o §4 |
| **Backup off-site** | Desde a [ADR-029](00-decisoes.md) não há backup nosso: são o snapshot da VPS (embutido no plano, com custo se subir a frequência) e o snapshot de projeto do Dokploy para o R2, que tem storage + operações. | R$ 5–30/mês |
| **Conta PJ + contador** | Emitir nota para clínica exige CNPJ. | R$ 200–400/mês |
| **Gateway de pagamento** | Cobrar da clínica tem taxa sobre a receita, não sobre o custo. | ~4% + R$ 0,40/transação |
| **Caixa de e-mail do domínio** | Resend **envia**, não **recebe**. `contato@` precisa de Zoho/Workspace. | R$ 0–30/mês |
| **Monitoramento externo** | Loki/Grafana rodam **no mesmo host** — se o host cair, o alerta cai junto. Uptime externo é linha à parte. | R$ 0–50/mês |
| **Sentry** | Decisão em aberto no [doc 78](78-sentry-vale-a-pena.md); tem etiqueta de preço. | conforme decisão |
| **Renovação Hostinger** | Preço de VPS costuma ser promocional em contrato longo e **subir na renovação**. | pode ser +50–100% |

---

## 7. Perguntas a confirmar antes de fechar qualquer número

1. **O número de WhatsApp é um só, ou um por clínica?** Define se os US$ 4 são piso (§2) ou custo
   marginal por clínica (§5). É a variável de maior impacto na curva.
2. **Os R$ 0,05 da Zernio incluem a tarifa da Meta?** Define se o §4 está certo ou pela metade.
3. **Os R$ 0,05 valem igual para enviada e recebida?** A lista diz que sim; confirmar, porque
   resposta de paciente é volume que não controlamos.
4. ~~**KVM 2 ou KVM 4?**~~ **RESPONDIDA (2026-07-31): KVM 2, sem corte nenhum.** A premissa da
   pergunta ("manter o modelo inteiro em 8 GB não é uma das opções") era falsa — vinha de uma
   estimativa que somava teto de container como consumo. Medido: **3,5 GB com tudo no ar**. Ver
   [ADR-023](00-decisoes.md) e
   [doc 87 §2.1](87-servidor-hostinger-riscos-e-cuidados.md#21-o-que-a-máquina-de-verdade-mediu-2026-07-31--a-estimativa-acima-estava-errada).
5. **R$ 108,99 é preço de contrato ou de renovação?** E por quantos meses. **Continua aberta, e
   subiu de importância**: agora é o único risco de preço do piso, e o §6 já registra que VPS
   costuma ser promocional em contrato longo e subir +50–100% na renovação.
6. ~~**Qual o preço real do KVM 4?**~~ **Deixou de bloquear** — o KVM 4 não foi contratado. Volta a
   importar só se o D-21 (carga real) mostrar que 8 GB aperta.

---

## 8. Custo de desenvolvimento — fora da conta operacional, de propósito

**Assinatura Claude Max 20×: US$ 200/mês ≈ R$ 1.138/mês.**

Está numa seção separada porque **não é a mesma natureza** das linhas acima, e somar as duas produz
um número que não significa nada:

- **Não escala com clínica nem com uso.** Vinte clínicas ou zero, o custo é o mesmo. Não entra em
  custo por atendimento nem em qualquer conta de margem.
- **Tem prazo, ao contrário dos outros.** É custo de **construir**; cai ou some quando o ritmo de
  desenvolvimento cair. Servidor e WhatsApp são custo de **operar** e duram enquanto o produto durar.
- **A comparação honesta é com desenvolvedor, não com servidor.** R$ 1.138/mês contra o custo de
  escrever o mesmo software de outra forma — não contra os R$ 246 de infraestrutura.

Para dar a dimensão sem misturar: hoje, **construir custa ~4,6× mais que operar** (R$ 1.138 vs.
R$ 246). Essa razão inverte conforme clínicas entram — e o ponto em que ela cruza 1:1 é **~17
clínicas** pela curva do §5.
