defmodule ApiWeb.Plugs.RequireScope do
  @moduledoc """
  Recusa com **401** quem chegou sem `Api.Scope` montado.

  ## Por que ele existe, se todo controller já tem guarda

  O pipeline `:authenticated` **não autentica** — ele carrega. Nenhum dos seus quatro plugs
  `halt`a por falta de sessão: `load_from_session` não exige usuário, `VerifyTokenSubject` tem
  cláusula de passagem quando não há `current_user`, e `LoadScope` faz `assign(conn, :scope, nil)`.
  Todo 401 do sistema vinha da guarda do **controller** (`with_member_scope` e irmãs), não do
  pipeline (doc 96, S-4).

  Isso é seguro exatamente enquanto toda rota do escopo tiver guarda própria — e já havia uma que
  não tinha: o `forward "/", ApiWeb.AshJsonApiRouter` mais o Swagger UI. Medido antes do conserto,
  sem cookie nenhum:

      $ curl -s -o /dev/null -w "%{http_code}" http://localhost:4010/api/json/swaggerui
      200

  O impacto imediato era baixo porque `Api.Meta` está vazio e o Traefik não roteia `/api/json`. O
  risco é o **próximo** recurso adicionado ao `Api.Meta`: ele nasce roteado e anônimo, dependendo
  só da própria policy. O moduledoc de `Api.Meta` já registra a lição da auditoria doc 13 (o
  recurso `Ping` publicava escrita anônima) — a plumbing que causou aquilo continuava de pé.

  Este plug é **redundante em 100% das rotas que têm guarda de controller**, e é precisamente por
  isso que ele é barato: ele não muda o comportamento de nada que já funciona, e fecha a classe de
  rota que esquece a guarda.

  O corpo do 401 é o mesmo de `ApiWeb.TenantScope.unauthorized/1` — fonte única (doc 96, H-2).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{scope: %Api.Scope{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, ~s({"error":"unauthenticated"}))
    |> halt()
  end
end
