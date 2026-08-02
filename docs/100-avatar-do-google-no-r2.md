# 100 — A foto de perfil do Google, copiada para o nosso bucket

**Data:** 2026-08-01 · **Decisão:** [ADR-026](00-decisoes.md) · **Fatia:** login com Google
(ADR-015) + storage (ADR-008)

O pedido foi curto: *"pegar avatar_url quando loga com o Google, fazendo upload no R2"*. Este doc
registra o que foi construído, as decisões que o pedido não fixava, e o que **ainda não foi
provado ao vivo**.

## 1. O caminho, ponta a ponta

```
login Google → user_info.picture  ─┐
                                   │  (mesma transação do upsert do User)
                          SyncGoogleAvatar enfileira ── só na 1ª vez da conta
                                   │
                            AvatarSyncJob (fila notifications)
                                   │
     GET googleusercontent.com ────┤  redirect: false · teto de 2 MB no coletor
                                   │
     magic bytes → PNG/JPEG/WEBP ──┤  o tipo DECLARADO não é usado
                                   │
        Api.Storage.put/3 no R2 ───┤  chave user/<user_id>/avatar.<ext>
                                   │
    users.avatar_key + avatar_origem
                                   │
        GET /api/auth/me ──────────┤  presign_get de 15 min
                                   │
              <img> no UserAvatar ─┘  (img-src da CSP autoriza o bucket)
```

Arquivos: `api/lib/api/accounts/user/avatar.ex` (regras puras),
`api/lib/api/accounts/user/changes/sync_google_avatar.ex` (quando enfileirar),
`api/lib/api/accounts/avatar_sync_job.ex` (o trabalho), `api/lib/api/storage/magic_bytes.ex`
(farejador compartilhado com o anexo), `web/src/lib/components/shell/UserAvatar.svelte` (a foto ou
as iniciais, num lugar só).

## 2. As cinco decisões que o pedido não fixava

| Decisão | Por quê |
|---|---|
| **Copiar os bytes, não guardar o link do Google** | Guardar a URL faria o browser do usuário discar para o `googleusercontent.com` em toda tela com avatar — a CSP teria de abrir esse destino, e o Google ganharia sinal de quem usa um sistema de clínica e quando. Além disso o link morre quando a pessoa troca a foto lá. Ver ADR-026 |
| **Buscar uma vez por conta, no cadastro** | Decisão de produto (2026-08-01). `register_with_google` é a mesma ação para cadastro e login, então o gatilho não é o ponto de entrada e sim o estado: enquanto `avatar_key` e `avatar_origem` forem nulas, a conta nunca passou pela busca. Custo aceito: **trocar a foto no Google não repropaga**. Ganho: o login não carrega trabalho recorrente nenhum — nem uma comparação de URL |
| **Job, não dentro do login** | O callback OAuth é uma página em branco esperando resposta: somar a latência do CDN alheio ao login, e fazer o login **falhar** quando o download falha, por causa de um enfeite |
| **Allowlist de host (`*.googleusercontent.com`, só https)** | O `user_info` vem verificado, mas o `picture` dentro dele é uma string que vira um `GET` **do servidor**: sem allowlist é SSRF (`169.254.169.254`, `db:5432`, qualquer serviço da rede do compose). `redirect: false` é a outra metade — senão a checagem valeria só para o primeiro salto |
| **Magic bytes, allowlist só de imagem** | Mesma postura do anexo (doc 51): o `Content-Type` da resposta é do outro lado. PDF é tipo que o farejador **conhece** e que o avatar **recusa** — a diferença entre as duas coisas é o motivo de a allowlist ficar no domínio e o farejador em `Api.Storage` |
| **`/me` devolve URL assinada, não a chave** | A chave é o endereço interno do bucket e o cliente não tem o que fazer com ela. TTL de 15 min (contra 5 do anexo) porque o consumo é um `<img>` montado a cada carga do layout, não um clique que abre aba |

## 3. O que mudou fora da fatia

- **`Api.Storage` ganhou `put/3`** — a primeira operação em que os bytes **passam pelo BEAM**. É
  exceção deliberada e está escrita no moduledoc: aqui não há browser do outro lado. O que o
  usuário sobe continua indo por `presign_put`.
- **`farejar/1` saiu de `Attachment.Conteudo` para `Api.Storage.MagicBytes`** (o `Conteudo` agora
  delega). Dois caminhos fazem a mesma pergunta sobre bytes vindos de fora; a allowlist continua
  sendo de cada domínio.
- **`img-src` da CSP** passou a derivar de `R2_ACCOUNT_ID`, como o `connect-src` já derivava
  (`web/src/lib/csp.js`). Sem isso a foto é bloqueada com o motivo só no console — o mesmo modo de
  falha do `PUT` do anexo (doc 51 §5.3). **Não há variável nova**: é a mesma do build.
- **`user_json/1` no `AuthController`** — `/me` e o PATCH de perfil descreviam o usuário com dois
  literais iguais; o `avatar_url` seria o campo que ficaria só num deles.

## 4. O que os testes provam (e o que não)

Suíte cheia depois da fatia: **1837 testes, 0 falhas, 89,9%** de cobertura no backend; **2431
testes, 93,0%** no web. Os dois gates (`mix coveralls`, `npm run coverage`) passam.

Provado por teste: a allowlist de host (inclusive `lh3.googleusercontent.com.evil.example`, que
não passa); a recusa de PDF/SVG/HTML; o teto de tamanho; a distinção **cancelar × retentar** (4xx
e conteúdo recusado não retentam, 5xx e falha de transporte retentam); o objeto antigo apagado
quando a extensão muda; a busca acontecendo **uma vez só** — nem no login seguinte, nem quando a
foto muda no Google, nem quando a anterior foi recusada (o carimbo em `avatar_origem`), mas
**sim** na conta que nasceu por magic link e só depois liga o Google; a foto sobrevivendo ao
próximo login (fora do `upsert_fields`); e o `/me` devolvendo URL assinada sem vazar a chave.

**O que NÃO está provado, e por quê:**

1. **O `PUT` real no R2 — não pela suíte; medido à mão.** `Api.Storage.R2.put/3` fala HTTP e a
   suíte não fala com o Cloudflare (mesma situação de `head`, `get_range` e `delete`, que o
   `r2_test.exs` já declara fora do alcance); só o caminho "sem credencial não assina nada" está
   coberto por teste. O caminho real foi exercitado em 2026-08-01 contra o bucket de dev, com uma
   chave descartável apagada logo depois:

   ```
   configured? true | adapter Api.Storage.R2
   put        -> :ok
   head       -> {:ok, %{bytes: 33}}      # o PNG de 33 bytes que subiu
   magic bytes-> {:ok, "image/png"}       # lidos de volta do bucket por GET de faixa
   presign GET-> 200                      # a URL assinada serve o objeto
   delete     -> :ok
   head depois-> {:error, :not_found}
   ```

   Ou seja: o `PUT` assinado, o `HEAD`, o `GET` de faixa, a URL assinada de leitura e o `DELETE`
   funcionam contra o R2 de verdade. **O que continua sem prova é o encadeamento** desses passos
   pelo job com uma foto vinda do Google.
2. **A parada do download no meio.** Com o `Req.Test`, o corpo chega numa chamada só; o teste do
   job prova a *recusa*, e `AvatarSyncJob.coletor/1` é testado direto para provar a *parada*. É
   contra o Finch real que ela importa, e ali nenhum teste da suíte chega.
3. **O fluxo OAuth de ponta a ponta.** A suíte exercita `register_with_google` pela ação, não pelo
   hand-off do Assent (que já era assim antes desta fatia).

## 5. Pontas soltas conhecidas

- **Não há upload de foto pelo usuário.** Quem entra por magic link continua com as iniciais. O
  desenho não impede (a chave é por `user_id`, não por origem), mas a tela e a ação de escrita não
  existem.
- **Objeto órfão se um `User` for apagado.** Hoje não há ação de destroy em `User`, então o caminho
  não é alcançável; quando a eliminação da LGPD (`50 §D-1`) entrar, ela precisa apagar
  `avatar_key` junto — mesma ordem que o anexo já exige.
- **A foto nunca se atualiza.** A busca é uma por conta; trocar a foto no Google não repropaga, e
  não há tela para trocar aqui. Reprocessar uma conta hoje é `UPDATE users SET avatar_key = NULL,
  avatar_origem = NULL` e um login — operação de banco, não de produto. Quando o upload de foto
  pelo próprio usuário existir, ele resolve os dois casos.
- **A janela do primeiro render.** No cadastro, o job corre contra o redirect: se o layout carregar
  antes de o job terminar, o primeiro render mostra as iniciais e a foto entra na navegação
  seguinte. O fluxo de conta nova passa por `/comecar` → onboarding → `/agenda`, e cada redirect
  refaz o `/me`, então na prática tende a se resolver sozinho — **não medido em login real**.
