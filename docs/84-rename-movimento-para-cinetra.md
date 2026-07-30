# 84 — Rename `movimento`/`moving` → `cinetra`

Fechamento do rebrand: a UI já era Cinetra desde a fatia da marca (ver
[`docs/19`](19-fidelidade-shell-interface.md)), mas o **encanamento** ainda era `movimento` — role
do banco, namespace das GUCs, nomes de banco, labels do Traefik. Este doc registra o que mudou, o
que ficou de propósito, e um bug que o rename destampou.

## 1. O tamanho real do problema

`grep -ri` devolvia **1671 ocorrências em 187 arquivos**, o que assusta e engana. A quebra:

| Categoria | Ocorrências | Destino |
| --- | --- | --- |
| Path `interface/Movimento.dc.html` | 968 | **mantido** (§3) |
| Namespace Elixir antigo `Movimento.*` nos docs de projeto | ~130 | **mantido** (§3) |
| Role `movimento_app` | 191 | → `cinetra_app` |
| GUCs `movimento.*` | 59 | → `cinetra.*` |
| Hosts/apps do Fly (`movimento-api.fly.dev`, …) | 60 | **apagados** (§4) |
| Bancos `movimento_dev` / `_test` / `_prod_smoke` / `_bff_test` | 20 | → `cinetra_*` |
| Labels Traefik `movimento-api-*` / `movimento-web-*` | 20 | → `cinetra-*` |
| Prosa de marca ("o Movimento", "Studio Movimento") | ~20 | → Cinetra |
| **Falsos positivos** (`removing`, "um movimento vira arraste") | ~35 | intocados |

Os falsos positivos merecem nota porque um `sed` ingênuo os destruiria: `removing`/`removingBusy`
em [`fila/+page.svelte`](../web/src/routes/(app)/fila/+page.svelte) contém "moving", e "movimento"
é substantivo comum em [`agenda-drag.ts`](../web/src/lib/agenda-drag.ts) ("um movimento vira
arraste") e [`FlowArt.svelte`](../web/src/lib/components/cinetra/FlowArt.svelte) ("sessões em
movimento" — é a arte da marca, descrevendo movimento de verdade).

## 2. O item de risco: o namespace das GUCs

`movimento.clinic_id` não é um nome qualquer — é lido por **17 policies de RLS em 17 tabelas**
(ADR-018), mais as duas GUCs de porta única da comunicação com o paciente
(`movimento.provider_message_id` e `movimento.message_id`, [doc 52 §10.2](52-comunicacao-com-o-paciente.md)).

O modo de falha é o pior possível: **GUC que a policy não lê é GUC ausente, e a RLS falha
FECHANDO**. Se o código passasse a setar `cinetra.clinic_id` enquanto as policies ainda lessem
`movimento.clinic_id`, toda leitura por-tenant voltaria vazia e toda escrita estouraria — sem erro
que apontasse para a causa, e com a suíte inteira verde (`mix test` roda como superusuário e
bypassa RLS).

**Produção não está provisionada** ([doc 59](59-deploy-dokploy-oci.md)), então não foi preciso
expand-contract. O caminho foi:

1. reescrever o texto das 14 `*_rls.exs` antigas — resolve **banco novo** (CI, dev recriado,
   produção quando existir), que roda as migrations do zero;
2. adicionar
   [`20260729120000_rename_tenant_guc_to_cinetra.exs`](../api/priv/repo/migrations/20260729120000_rename_tenant_guc_to_cinetra.exs),
   que dropa e recria as 17 policies — resolve **banco já migrado**, onde o Ecto não re-roda
   migration aplicada.

A migration roda **em transação** de propósito (sem `@disable_ddl_transaction`): metade das tabelas
lendo o GUC novo e metade o velho é exatamente o estado que nenhum teste pega.

> Ela é o mesmo desenho de sempre: `DROP POLICY IF EXISTS` + `CREATE POLICY`, com os **três**
> formatos de predicado preservados — o simples (15 tabelas), o de `message_opt_outs` (aceita
> `clinic_id IS NULL`, que é o opt-out global do paciente) e o de `messages` (as duas portas sem
> sessão abrem só a LEITURA; o `WITH CHECK` continua exigindo a clínica).

## 3. O que NÃO mudou, e por quê

**`interface/Movimento.dc.html`** — o [CLAUDE.md](../CLAUDE.md) diz que `interface/` é regenerado
por ferramenta e não se edita à mão, e a ferramenta já apagou arquivo feito à mão antes. Se o
projeto na ferramenta ainda se chama "Movimento", o rename volta atrás na próxima geração e ainda
quebra 968 links. O arquivo é artefato histórico; o nome dele é o nome que ele tinha.

**O namespace `Movimento.*` nos docs 00/01/04/08** — descreve um namespace de módulo que **nunca
existiu no código** (o real sempre foi `Api.*`; o [doc 22 §1](22-horarios-e-excecoes.md) já
registra isso). Trocar para `Cinetra.*` inventaria um segundo namespace falso; trocar para `Api.*`
reescreveria um documento de proveniência. Fica como está.

**A discussão de marca no [doc 37](37-homologacao-andreza.md) (D-H1) e no
[doc 64](64-leva-andreza-plano.md)** — são o registro de que houve confusão entre Moving, Cinetra e
Movimento. Reescrevê-los apagaria justamente a decisão que este doc conclui.

**O diretório e o repositório continuam `moving`** — decisão de não mexer agora. O redirect do
GitHub segura clones antigos quando for a hora; o comentário no
[`docker-compose.yml`](../docker-compose.yml) explica por que o `name:` do projeto é explícito
(sem ele o compose herdaria o nome do diretório).

## 4. O Fly saiu

`api/fly.toml` e `web/fly.toml` foram **apagados** — o deploy é Dokploy/OCI desde o
[doc 59](59-deploy-dokploy-oci.md). Conferido antes de apagar que o
[`compose.dokploy.yml`](../compose.dokploy.yml) cobre tudo que eles faziam:

- `release_command` → serviço `migrate` (roda até o fim antes de a API subir);
- `[build.args] API_PUBLIC_ORIGIN` → `args:` do serviço `web`;
- `[build.args] R2_ACCOUNT_ID` → idem — **isso fecha a pendência** anotada na fatia de anexos
  ([doc 51](51-ficha-anexos-e-storage.md)), que pedia o R2 no `web/fly.toml`.

Todas as demais menções a Fly fora dos `.toml` eram **comentário** — nenhuma URL de runtime
dependia do Fly (`seo.ts` e `sitemap.xml` derivam de `ORIGIN`). Os comentários foram reescritos
para a topologia real (Traefik, `args:`/`environment:`), preservando a lição que carregavam. As
menções a Fly que sobraram são deliberadas: explicam **por que** o default do §5 mudou.

## 5. Bug destampado pelo rename: o header de IP confiável

Ao varrer o Fly, apareceu [`ApiWeb.ClientIp`](../api/lib/api_web/client_ip.ex):

```elixir
@default_trusted ["fly-client-ip"]
```

E `:trusted_client_ip_headers` **não é configurado em nenhum ambiente** — nem no
`compose.dokploy.yml`, nem no `runtime.exs`. Ou seja: em produção, sob Traefik, valia o default.

O moduledoc do próprio arquivo previu o problema com todas as letras — "um header só é confiável se
a topologia garante que alguém o sobrescreve" e "ao trocar de edge, ajuste a lista **junto** com a
troca do proxy". A edge foi trocada (doc 59) e a lista não. Sob Traefik **ninguém escreve nem
remove** `fly-client-ip`, então quem o preenche é o próprio cliente: forjar `Fly-Client-IP` a cada
request dá uma chave de rate limit nova por request e zera os **dois** limitadores (o global e o
anti-spam do magic link, [doc 13 causa A](13-auditoria-bate-volta-fundacao-auth.md)) — sem nada
quebrar à vista. É exatamente a causa B do [doc 68](68-bate-volta-rate-limit-global.md), de volta
por outra porta.

Pela regra do projeto, virou teste antes de virar conserto:

1. teste que falha em [`client_ip_test.exs`](../api/test/api_web/client_ip_test.exs) — rodado e
   visto **vermelho** (`o header forjável não pode vencer no default`);
2. conserto: `@default_trusted []`. Nenhum header de vendor é confiável até que o deploy declare
   que a edge o sobrescreve; cai-se no `x-forwarded-for`, que é o que a topologia garante;
3. verde, e a suíte inteira junto.

Os dois testes que exercitavam a **prioridade** dependiam implicitamente do default da Fly — foram
reescritos para declarar a edge explicitamente (`com_edge_confiavel/1`), que é como um ambiente com
edge de verdade se configura.

> **Fica em aberto** (não é regressão deste rename, é anterior): `x-forwarded-for` é montado por
> concatenação, e o Traefik **anexa** o IP real ao valor que chegou. `List.first/1` pega o primeiro
> item, que é atacante-controlável se o cliente mandar o header. A defesa hoje é a API ser interna
> (só `/socket` e `/webhooks` são públicos). Tratar isso é escolher a profundidade certa do XFF —
> assunto próprio, registrado em [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md).

## 6. A migração do banco de dev

O banco de dev tinha dado real, então foi migrado no lugar, não recriado:

```sql
ALTER ROLE movimento_app RENAME TO cinetra_app;
ALTER ROLE cinetra_app PASSWORD 'cinetra_app';
ALTER DATABASE movimento_dev  RENAME TO cinetra_dev;
```

O `ALTER ROLE ... RENAME` preserva os GRANTs (eles seguem o OID, não o nome) e as policies são
`TO public`, então nada precisou ser re-concedido. O `RENAME` do banco exigiu derrubar a única
sessão aberta — era o `cinetra_metrics` do painel do Grafana ([doc 73](73-dashboards-do-log-ao-banco.md)).

O `movimento_test` virou órfão (o `cinetra_test` já tinha sido recriado do zero pelo `mix test`) e
foi dropado.

## 7. Verificação

| Gate | Resultado |
| --- | --- |
| `mix format --check-formatted` | limpo |
| `mix compile --warnings-as-errors` | limpo |
| `mix test` | **1645 testes + 18 doctests, 0 falhas** |
| `mix test --only rls` (como `cinetra_app`, NOBYPASSRLS) | **0 falhas** |
| `npm run check` (svelte-check) | 0 erros, 0 warnings |
| `npm run coverage` | **180 arquivos, 0 falhas** — 92,8% stmts / 78,11% branch / 93,7% lines |
| `pg_policies` no banco vivo | **17 policies em `cinetra`, 0 em `movimento`** |
| App ao vivo | serve 200 com dado, conectado como `cinetra_app` |

O gate de RLS é o que importa aqui: ele conecta como `cinetra_app` (NOBYPASSRLS) e é o único que
enxerga a coerência entre a GUC que o código seta e a que a policy lê. `mix test` sozinho seria
verde mesmo com o rename pela metade.

> **Nota sobre o runner do web:** com o paralelismo default o Vitest estoura timeout no WSL2 e
> acusa falhas que variam de execução para execução (9, 8, 15…). Com `--maxWorkers=4` fica
> determinístico e verde. Não é regressão — os arquivos que "falhavam" incluíam
> `src/routes/page.svelte.test.ts`, que este rename nem tocou.

## 8. Pendências

- **Repositório no GitHub** continua `Transmuta/moving` (§3) — decisão de não mexer agora.
- **Segredos do Dokploy**: `DATABASE_APP_USER`/`DATABASE_APP_PASSWORD` do stack precisam virar
  `cinetra_app` **antes** do primeiro deploy, senão o app não conecta. Como produção ainda não foi
  provisionada, é só preencher certo na hora.
- **Stack de observabilidade local** está com `alloy`, `tempo`, `grafana`, `prometheus` e `loki`
  parados com `Exited (127)`. Não tem relação com o rename (rename de banco não produz "command not
  found"), mas precisa de olhada quando for usar os painéis. Ao subir de novo, o
  `METRICS_DB_NAME` default já aponta para `cinetra_dev`.
- **`OBS_PROJETOS`**: o exemplo dizia `moving`, que não casaria com nada — o projeto do compose
  agora é `cinetra`. Corrigido, mas se houver um valor setado no ambiente de quem roda a stack,
  ele precisa ser atualizado à mão.
