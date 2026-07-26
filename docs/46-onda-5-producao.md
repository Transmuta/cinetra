# 46 — Onda 5: endurecimento de produção (Frente 11)

A onda que o [doc 35](35-plano-execucao-backlog.md) põe **antes do primeiro deploy real**: H59
(cookie `secure`, CSP/HSTS/X-Frame, CSRF do sign-out), S3 (hosts da CSP por ambiente), S2 (token
do WS fora da query string) e H64 (semântica de `ON DELETE` por relação).

**Estado:** construída e verificada em 2026-07-26. Números ao fim da seção 7.

---

## 1. O levantamento veio antes do código — e mudou a onda

O doc 35 lista os quatro itens como se fossem quatro pendências inteiras. Medido no código, a
maior parte do H59 **já estava feita** desde a fatia de produção do doc 13: CSP com nonce
(`kit.csp`), `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy` e o sign-out via POST (que é o
que fecha o CSRF de logout). O cookie de sessão do web também: o SvelteKit ativa `Secure`
sozinho fora de `localhost`, e o default dele **falha fechado** — num deploy http acidental o
cookie simplesmente não é gravado, em vez de trafegar em claro. Trocar isso por uma checagem de
protocolo nossa seria trocar um default seguro por um menos seguro; ficou como está, agora por
escrito.

O que sobrou do H59 foi **um** item — e não estava na lista, porque o projeto acreditava que
estava resolvido.

Em compensação, o levantamento achou **três coisas que não estavam em item nenhum** e que
quebrariam o primeiro deploy (§5 e §6).

## 2. H59 — o HSTS que ninguém emitia

O [doc 17](17-deploy-fly.md) dizia, na primeira linha: *"O TLS, o redirect http→https e o HSTS
são da edge do Fly (`force_https`)"*. O `prod.exs` repetia a mesma ideia atribuindo-a a um proxy
Caddy que **não existe mais** no projeto (o deploy é Fly desde o doc 17; o `compose.prod.yml` é
smoke local).

As duas versões estavam erradas pelo mesmo motivo: `force_https` é **redirect**, não header. O
proxy do Fly não emite `Strict-Transport-Security` — o que existe em `*.fly.dev` é HSTS do
domínio compartilhado, que não acompanha domínio próprio. Confirmado na documentação e no fórum
do Fly: *"there is no way to configure response headers at the Fly proxy layer besides sending
them from your application"*.

Por que passou tanto tempo despercebido: **o redirect esconde o sintoma.** Com `force_https`,
digitar `http://` no browser leva a `https://` e tudo parece certo. O que o HSTS protege é
exatamente o que o redirect não protege — a **primeira** requisição, antes do redirect, e o
ataque de downgrade em rede hostil.

Agora sai do BFF (`web/src/hooks.server.ts`), com `max-age=63072000; includeSubDomains` (dois
anos, o mínimo que a preload list exige). **Sem `preload`** de propósito: entrar naquela lista é
decisão humana e sair dela leva meses.

A condição é o **protocolo do request**, não uma flag de ambiente:

- sobre http o header é ignorado por especificação (RFC 6797 §8.1), então emiti-lo em dev só
  treinaria o olho a ver um header que não faz nada;
- e uma flag de ambiente daria HSTS de mentira num deploy http acidental — o header sairia, o
  browser o descartaria, e a auditoria seguinte marcaria "feito".

A API **não** ganhou o header: o browser só a alcança por WebSocket (§5), e HSTS em resposta de
handshake não protege navegação nenhuma.

## 3. S3 — a CSP carregava os dois ambientes

O `connect-src` listava, fixos, `localhost:4010` **e** `movimento-api.fly.dev`: o build de
produção levava a origem de dev junto. Inexplorável (ninguém serve `localhost` do browser da
vítima), mas é a CSP afirmando algo que o desenho não afirma — e o próximo host entraria na
lista pelo mesmo caminho.

Agora sai de `API_PUBLIC_ORIGIN`, uma origem por build, derivando o par http(s)/ws(s) pela
**mesma regra** de `socketUrl` (`realtime.ts`): quem monta a URL do socket e quem a autoriza
precisam concordar, senão o socket morre por um header que ninguém lê até o browser reclamar.

**O preço, escrito no Dockerfile:** a `kit.csp` é fixada no **build**, não em runtime. Por isso a
origem entra por `ARG`/`ENV` do `Dockerfile.prod` e por `[build.args]` do `fly.toml` — o `[env]`
do fly.toml só existe quando o container sobe, tarde demais para o header. A consequência é que a
**imagem fica atada ao ambiente**: construir para produção e rodar em staging serve o header
errado, e o sintoma é o WebSocket bloqueado no console do browser, não um erro de servidor.

Prova, pelo dev rodando:

```
content-security-policy: … connect-src 'self' http://localhost:4010 ws://localhost:4010; …
```

## 4. S2 — o token saiu da query string (e o interruptor estava no lugar errado)

O token efêmero de 15 min viajava em `?token=…` na URL do WebSocket, onde vaza para log de proxy.
O doc 30 registrava como trade-off aceito.

Deixou de ser trade-off: **o Phoenix 1.8 e o phoenix-js 1.8 já resolvem isso de fábrica** — as
duas versões que o projeto já usava. `auth_token: true` no endpoint e `authToken:` no cliente
movem o token para o subprotocolo `Sec-WebSocket-Protocol`, que é a única alternativa real (o
browser não deixa pôr header em WebSocket).

A porta antiga foi **fechada, não duplicada**. Enquanto o param valesse, um token colhido de log
seguiria conectando e a mudança não fecharia nada. Medido, com o servidor rodando:

| requisição | resposta |
| --- | --- |
| subprotocolo com token válido | **101 Switching Protocols** (`sec-websocket-protocol: phoenix`) |
| token cru na **query string** | **403** |
| subprotocolo com token adulterado | **403** |
| sem token nenhum | **403** |

### O achado que só o browser pegou

Escrito como `websocket: [auth_token: true]` — que é onde a documentação do Phoenix descreve a
opção — **todo handshake real vira 403, com a suíte inteira verde**.

A causa está no `Phoenix.Endpoint`: `put_auth_token/2` faz
`Keyword.put(websocket, :auth_token, opts[:auth_token])`, lendo a chave do **nível do socket**.
Ausente ali fora, `opts[:auth_token]` é `nil` — e o `Keyword.put` sobrescreve com `nil` o `true`
que estava dentro. A opção é do socket:

```elixir
socket "/socket", ApiWeb.UserSocket, auth_token: true, websocket: true, longpoll: false
```

Por que os seis testes de socket passaram mesmo assim: o `Phoenix.ChannelTest` injeta
`connect_info` **direto** e nunca atravessa o transporte, que é onde o subprotocolo é lido. É a
lição do doc 43 cobrada de novo — clicar no browser acha o que a suíte não acha —, e a resposta
foi um teste que lê a configuração compilada (`ApiWeb.Endpoint.__sockets__()`), **provado por
mutação**: repondo `websocket: [auth_token: true]`, ele fica vermelho.

De quebra, os três clientes (agenda, fila, notificações) montavam o mesmo bloco de socket
copiado; o S2 entrou num `abrirSocket/2` só, em vez de três vezes.

## 5. H64 — a semântica de `ON DELETE`, e por que o teste lê o catálogo

Nenhum recurso do projeto tem ação `destroy` sobre `User`, `Clinic`, `Patient`, `Professional` ou
`Package`: **tudo arquiva**. A semântica de deleção é, portanto, latente — ela não roda hoje, mas
decide o que acontece quando a eliminação da LGPD (F8) for construída e o que acontece se alguém
apagar à mão em produção. Assertir sobre a ação seria assertir sobre código que não existe; a
regra vive na constraint, e é a constraint que `test/api/on_delete_test.exs` lê.

Medido no banco (não lido no código): **30 das 32 FKs já eram deliberadas**. As exceções eram
todas do mesmo tipo — o **autor** de alguma coisa:

| relação | era | virou | por quê |
| --- | --- | --- | --- |
| `appointments.created_by_id` | `NO ACTION` | `SET NULL` | autoria é auditoria, não parte do dado; `NO ACTION` tornava impossível apagar um usuário que já criou qualquer agendamento — exatamente o que a F8 precisará fazer |
| `appointments_versions.user_id` | `NO ACTION` | `SET NULL` | o default do AshPaperTrail é `:nothing`; a trilha travava o `DELETE` do usuário. Perder o vínculo não apaga a versão: o diff continua lá |
| `attendances_versions.user_id` | `NO ACTION` | `SET NULL` | idem |
| `attendances.package_id` | **sem FK nenhuma** | `SET NULL` | era "gancho da Fatia 3, sem FK", escrito quando `Package` ainda não era tabela. Virou relação de verdade: o projeto já tratava a coluna como referência (a massa por pacote opera sobre presenças por ela), só sem o banco garantir nada |

O contrato tem **duas** asserções, e a segunda é a que importa a longo prazo: além de conferir
linha a linha, o teste falha se **qualquer FK nova** aparecer sem decisão declarada. Sem ela, a
causa D do doc 13 renasce por omissão — que é como ela nasceu da primeira vez.

### Duas armadilhas na migration, as duas registradas no arquivo

1. **O codegen emitiu um `CREATE INDEX` de um índice que já existia.** Com `index [:package_id]`
   ainda em `custom_indexes` e a nova relação declarando o mesmo `(clinic_id, package_id)`, a
   migration morreu com `42P07` na primeira execução. Tirar a declaração duplicada resolveu a
   causa, mas o codegen seguinte passou a emitir `drop` + `create` do **mesmo** índice — churn
   puro numa tabela de 10.219 linhas, e um `CREATE INDEX` comum toma `ShareLock`, que fila todo
   `INSERT`/`UPDATE` enquanto constrói ([regra do projeto](../.claude/rules/migrations.md)). O par
   foi removido à mão, com o porquê no `@moduledoc` da migration.
2. **Orfãos foram conferidos antes**, não depois: `attendances` com `package_id` apontando para
   pacote inexistente = **0** (de 4 linhas com pacote em 10.219). Sem isso, a criação da FK
   falharia no meio do deploy.

## 6. Três achados fora dos itens — dois bloqueavam o deploy

Nenhum deles é do escopo nominal da frente; todos vieram do levantamento.

**(a) O `GOOGLE_REDIRECT_URI` do doc 17 apontava para a API.** O callback do Google é uma rota do
**web** (`/auth/user/google/callback`), que repassa o `code` à API server-to-server e re-emite a
sessão no domínio do web — o browser **não** toca a API nesse fluxo. Seguir o doc cadastraria no
console do Google uma URL que a aplicação não serve, e o login por Google quebraria em produção
com um erro que só aparece do lado do Google. Corrigido, junto com o diagrama de arquitetura, que
listava o OAuth como acesso direto do browser à API.

**(b) O `prod.exs` descrevia um proxy Caddy que não existe** e atribuía o TLS/HSTS a ele. Ver §2.

**(c) `appointments.package_id` é coluna morta — e leva uma tarja de UI morta junto.**
Não corrigido: é decisão de produto. Medido: **0 de 10.212** agendamentos têm `package_id`
preenchido. A A2 (doc 41 etapa 2) moveu o pacote para a **presença** (D11: não existe pacote de
turma), e o argumento `package_id` das ações de `Appointment` carimba a `Attendance`, nunca a
coluna do bloco. Só que o serializador ainda envia `package_id` do bloco e o
`AppointmentBlock.svelte` ainda desenha **duas** marcas com ele — a tarja lateral teal e o ícone
de pacote —, que hoje **nunca aparecem**. Além do enfeite inerte, a coluna carrega o índice
`appointments_clinic_id_package_id_index`, mantido a cada escrita de uma tabela quente para uma
coluna sempre nula. As opções são apagar as duas marcas ou derivá-las das presenças do bloco
(fazendo a tarja voltar a funcionar) — a segunda é mudança de comportamento visível, e por isso
está aqui e não no diff.

## 7. Verde ao fim

- **API:** 1018 testes + 17 doctests, **0 falhas**, cobertura **91,2%** (piso 80); gate `:rls`
  **20/0** como `movimento_app`; `mix format --check-formatted` e `--warnings-as-errors` limpos.
- **Web:** **1286 testes / 0 falhas** em 137 arquivos, `svelte-check` **0 erros**, cobertura
  **91,5% stmts / 77,4% branches** (pisos 80/75).
- **Ao vivo:** WebSocket conectando e entrando nos tópicos pelo subprotocolo (`CONNECTED TO
  ApiWeb.UserSocket` + `JOINED clinic:…:agenda:…` + `JOINED notifications:…`), console do browser
  sem erro, CSP do dev sem host de produção, e as quatro FKs com a semântica nova conferidas em
  `pg_constraint`.
