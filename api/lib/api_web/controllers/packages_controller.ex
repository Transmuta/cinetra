defmodule ApiWeb.PackagesController do
  @moduledoc """
  Os pacotes (Fatia 3, doc 09). Molde do `WaitlistController`: `with_member_scope` na fronteira (o
  RBAC fino é da policy do recurso), `whitelist/2` no corpo, `error_response/2` na escada
  401/403/404/422. `clinic_id` nunca vem do corpo — é do `Ash.Scope`.

  ## A prévia e o save-gate

  `POST /preview` classifica a série sem escrever (o `occIssue` do protótipo). `POST /` cria: roda
  a mesma prévia server-side e **decide** — se há ocorrência fora do expediente, ou conflito sem
  `forcar`, devolve **422 com a prévia** (código `series_blocked`) para a tela reapresentar; senão
  cria o pacote e enfileira a materialização.

  Pausar/retomar/cancelar operam sobre a série inteira; a retomada reprojeta as sessões seguradas
  para o futuro (GAP-06), re-materializando via job.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  require Logger

  alias Api.Records
  alias Api.Packages
  alias ApiWeb.PackagesJSON

  # GET /api/patients/:patient_id/packages
  def index(conn, %{"patient_id" => patient_id}) do
    with_member_scope(conn, fn scope ->
      # Resolver o paciente ANTES de listar (doc 96, H-3). Sem isto, um id de outra clínica — ou
      # lixo — devolvia **200 com lista vazia**, indistinguível de "este paciente não tem pacote";
      # e um id não-UUID chegava cru em `Ash.Query.filter` e virava 400 com corpo de outro
      # formato, mais stacktrace no log. É o mesmo desenho de `PatientsController.history/2`.
      case Records.fetch_clinic_patient(scope, patient_id) do
        {:ok, nil} -> not_found(conn)
        {:ok, %{}} -> listar_pacotes(conn, scope, patient_id)
      end
    end)
  end

  defp listar_pacotes(conn, scope, patient_id) do
    packages = Packages.list_patient_packages(scope, patient_id)

    # A trilha de todos os pacotes numa leitura só (o cartão desenha as bolinhas). Buscar por
    # pacote seria um N+1 que cresce com o tempo de casa do paciente.
    trilhas = Packages.sessions_by_package(scope, packages)

    json(conn, %{
      packages: Enum.map(packages, &PackagesJSON.package(&1, Map.get(trilhas, &1.id, [])))
    })
  end

  # POST /api/packages/preview
  def preview(conn, params) do
    with_member_scope(conn, fn scope ->
      with {:ok, attrs} <- series_params(params),
           {:ok, previa} <- Packages.preview_series(scope, attrs) do
        json(conn, PackagesJSON.preview(previa))
      else
        :invalid -> bad_request(conn)
        {:error, motivo} -> series_error(conn, motivo)
      end
    end)
  end

  # POST /api/packages
  def create(conn, params) do
    with_member_scope(conn, fn scope ->
      forcar = Api.Params.truthy?(params["forcar"])

      with {:ok, attrs} <- series_params(params),
           {:ok, pkg} <- Packages.create_series(scope, attrs, forcar: forcar) do
        pkg = Packages.get_patient_package!(scope, pkg.id, load: derivados())
        conn |> put_status(:created) |> json(%{package: PackagesJSON.package(pkg)})
      else
        :invalid ->
          bad_request(conn)

        {:error, {gate, previa}} when gate in [:fora_expediente, :precisa_confirmar] ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "series_blocked", reason: gate, preview: PackagesJSON.preview(previa)})

        {:error, motivo} ->
          series_error(conn, motivo)
      end
    end)
  end

  # POST /api/packages/:id/pause
  def pause(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.pause_package(scope, id))
    end)
  end

  # POST /api/packages/:id/resume
  def resume(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.resume_package(scope, id))
    end)
  end

  # POST /api/packages/:id/cancel
  def cancel(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.cancel_package(scope, id))
    end)
  end

  # POST /api/packages/:id/sessions — o `+1` do ADR-011 (o `total` é editável; não há renovação).
  def add_session(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.add_session(scope, id))
    end)
  end

  # DELETE /api/packages/:id/sessions — o `−1`.
  #
  # **Sem `:appointment_id` no path**, diferente do contrato `09:445`: por D3 quem escolhe a sessão
  # é o servidor (a última **futura** não consumida), justamente para que o cliente não consiga
  # apontar uma sessão passada e reescrever histórico. Escolher qual sessão remover é trabalho da
  # agenda, com a sessão à vista — não do stepper da ficha.
  def remove_session(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.remove_session(scope, id))
    end)
  end

  # PATCH /api/packages/:id/grade — remarca as futuras para a grade nova (contrato 09:441).
  def adjust_grade(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope ->
      grade = %{
        dows: params["dows"],
        horarios: params["horarios"],
        professional_id: params["professional_id"]
      }

      transition(conn, scope, Packages.adjust_grade(scope, id, grade))
    end)
  end

  # GET /api/packages/:id/sessions — a trilha (estado de cada sessão da série).
  def sessions(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      # A leitura confirma o pacote pela porta de sempre (404 se não é desta clínica) antes de
      # listar — a trilha não pode ser um caminho lateral para descobrir id de outro tenant.
      # Pela versão que NÃO levanta: o bang produzia 404 com o corpo do `ash_phoenix`
      # (`{"errors":{"detail":...}}`) em vez do `{"error":"not_found"}` de todos os irmãos, e
      # **400** quando o id nem era UUID (doc 96, H-4).
      case Packages.fetch_patient_package(scope, id, load: []) do
        {:ok, nil} ->
          not_found(conn)

        {:ok, %{}} ->
          json(conn, %{
            sessions: Enum.map(Packages.list_sessions(scope, id), &PackagesJSON.session/1)
          })
      end
    end)
  end

  # POST /api/packages/:id/archive
  def archive(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.archive_package(scope, id))
    end)
  end

  # POST /api/packages/:id/bulk_adjust
  def bulk_adjust(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope ->
      bulk(conn, scope, id, Packages.bulk_adjust(scope, id, params))
    end)
  end

  # POST /api/packages/:id/bulk_cancel
  def bulk_cancel(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope ->
      bulk(conn, scope, id, Packages.bulk_cancel(scope, id, params))
    end)
  end

  # A resposta da massa devolve o pacote (os derivados mudaram) e **quantas** sessões foram
  # tocadas — a tela precisa do número para o "3 sessões remarcadas", e recontar no cliente daria
  # outro número (o cliente não sabe o recorte de futuras não-resolvidas).
  defp bulk(conn, scope, id, result) do
    case result do
      {:ok, %{afetadas: afetadas}} ->
        pkg = Packages.get_patient_package!(scope, id, load: derivados())
        json(conn, %{package: PackagesJSON.package(pkg), afetadas: afetadas})

      {:error, :not_found} ->
        not_found(conn)

      {:error, motivo} when is_atom(motivo) ->
        invalid(conn, motivo_da_massa(motivo))

      {:error, error} ->
        error_response(conn, error)
    end
  end

  defp motivo_da_massa(:nada_a_aplicar), do: "escolha o que aplicar: profissional e/ou horário"
  defp motivo_da_massa(:horario_invalido), do: "horário inválido"
  defp motivo_da_massa(:escopo_invalido), do: "escopo inválido"
  defp motivo_da_massa(outro), do: frase_desconhecida(outro)

  defp transition(conn, scope, result) do
    case result do
      {:ok, pkg} ->
        pkg = Packages.get_patient_package!(scope, pkg.id, load: derivados())
        json(conn, %{package: PackagesJSON.package(pkg)})

      {:error, :not_found} ->
        not_found(conn)

      # Recusa de regra do ciclo de vida (arquivar com sessão de pé, estado terminal): é 422 com a
      # razão em português, como a massa. Antes do `archive` não havia caso, e um átomo caía no
      # `error_response`, que espera erro do Ash.
      {:error, motivo} when is_atom(motivo) ->
        invalid(conn, motivo_do_ciclo(motivo))

      {:error, error} ->
        error_response(conn, error)
    end
  end

  defp motivo_do_ciclo(:sessoes_futuras),
    do: "ainda há sessões futuras neste pacote — cancele ou conclua antes de arquivar"

  defp motivo_do_ciclo(:status_invalido), do: "este pacote não aceita esta mudança agora"

  defp motivo_do_ciclo(:sem_sessao_futura),
    do: "não há sessão futura para remover — as que sobraram já aconteceram"

  defp motivo_do_ciclo(:abaixo_do_consumido),
    do: "o total não pode ficar abaixo das sessões já consumidas"

  defp motivo_do_ciclo(:profissional_invalido),
    do: "escolha um profissional desta clínica"

  defp motivo_do_ciclo(:profissional_inativo),
    do: "este profissional está arquivado — escolha outro para a grade"

  defp motivo_do_ciclo(:grade_vazia), do: "marque ao menos um dia da semana"
  defp motivo_do_ciclo(:horario_faltando), do: "cada dia marcado precisa de um horário"
  defp motivo_do_ciclo(:dia_invalido), do: "dia da semana inválido"
  defp motivo_do_ciclo(:grade_invalida), do: "grade inválida"
  defp motivo_do_ciclo(:sem_grade), do: "este pacote não tem grade"
  defp motivo_do_ciclo(:teto_do_pacote), do: "este pacote já está no número máximo de sessões"

  defp motivo_do_ciclo(:sem_data_na_grade),
    do: "a grade não tem data disponível daqui para a frente"

  defp motivo_do_ciclo(outro), do: frase_desconhecida(outro)

  # **O átomo desconhecido NÃO vai para a tela** — e este é o único lugar que decide isso.
  #
  # Havia TRÊS portas fazendo o contrário, cada uma do seu jeito: `motivo_do_ciclo/1` e
  # `motivo_da_massa/1` com `to_string/1`, e `series_error/2` com `inspect/1`. Bastava alguém
  # acrescentar um `{:error, :timeout}` ao domínio para a recepção ler "timeout" na tela como
  # explicação de não conseguir arquivar um pacote — e consertar só uma das três recriaria a
  # divergência que a tradução existe para evitar.
  #
  # O motivo não some: ele vai para o LOG, que é onde serve a quem pode agir sobre ele. Muda de
  # público, não de existência.
  defp frase_desconhecida(motivo) do
    Logger.warning("PackagesController: motivo sem frase — #{inspect(motivo)}")
    "não foi possível concluir esta operação"
  end

  # Extrai e valida os campos que criam a série. `data_inicio` chega como "AAAA-MM-DD"; a grade é
  # um mapa aninhado. Erro de forma vira `:invalid` (→ 400), sem estourar no domínio.
  defp series_params(params) do
    with %{"grade" => grade} when is_map(grade) <- params,
         {:ok, data_inicio} <- parse_date(params["data_inicio"]) do
      attrs =
        params
        |> whitelist([:nome, :total, :falta_punitiva, :cor, :patient_id, :appointment_type_id])
        |> Map.put(:data_inicio, data_inicio)
        |> Map.put(:grade, %{
          dows: grade["dows"],
          horarios: grade["horarios"],
          professional_id: grade["professional_id"]
        })

      {:ok, attrs}
    else
      _ -> :invalid
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error

  # Os erros do motor de série (grade vazia, horário faltando) viram 422 com a razão.
  # `reason` era `inspect(motivo)` — o átomo interno cru, e para um erro do Ash o **struct inteiro**
  # despejado numa string. Passa pela mesma tradução do ciclo de vida: uma tabela só para as duas
  # portas, senão elas divergem no dia em que alguém acrescenta um motivo em uma e esquece a outra.
  defp series_error(conn, motivo) when is_atom(motivo) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_series",
      reason: to_string(motivo),
      message: motivo_do_ciclo(motivo)
    })
  end

  # Erro do Ash (validação do recurso, conflito): tem máquina própria, com campo e mensagem.
  defp series_error(conn, motivo), do: error_response(conn, motivo)

  defp derivados, do: [:usadas, :restantes, :acabando, :schedule]
end
