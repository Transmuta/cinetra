defmodule ApiWeb.ProfessionalsController do
  @moduledoc """
  Diretório de profissionais da clínica (fatia Profissionais). Espelha
  `AppointmentTypesController`: lê o `Api.Scope` do request, chama os code interfaces do domínio
  com `scope:` e monta o JSON. O `clinic_id` vem **sempre** do escopo, nunca do corpo (09 §8).
  RBAC ADR-016: **leitura** (GET) liberada a qualquer membro ativo; **escrita** exige owner/admin.

  Superfícies separadas, como no protótipo o formulário edita seções distintas:

    * ficha — `GET/POST /professionals`, `GET/PATCH /professionals/:id`,
      `POST /professionals/:id/deactivate|reactivate` (arquivar, não apagar);
    * grade semanal — `PATCH /professionals/:id/hours` (substitui os dias enviados);
    * exceções de data — `POST /professionals/:id/exceptions`,
      `DELETE /professionals/:id/exceptions/:exception_id`.

  A grade e as exceções ficam **fora** do corpo da ficha: o web orquestra as chamadas (como já
  faz a tela de Horário da clínica), mantendo cada invariante na sua ação.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Directory
  alias Api.Scheduling

  # GET /api/professionals — ativos E arquivados (a tela filtra). Vai junto o expediente da
  # clínica (`clinic_hours`), que a coluna "Atendimento" usa para resolver os dias `:herda`.
  def index(conn, _params) do
    with_member_scope(conn, fn scope ->
      json(conn, %{
        professionals: Enum.map(Directory.list_clinic_professionals(scope), &prof_json/1),
        clinic_hours: Enum.map(Scheduling.list_clinic_hours(scope), &hours_row_json/1)
      })
    end)
  end

  # GET /api/professionals/:id — a ficha completa, com a grade e as exceções.
  def show(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      case Directory.fetch_clinic_professional(scope, id, load: [:weekly_hours, :exceptions]) do
        {:ok, %{} = prof} -> json(conn, %{professional: prof_json(prof, exceptions: true)})
        {:ok, nil} -> not_found(conn)
      end
    end)
  end

  # POST /api/professionals — cria a ficha (só o nome é obrigatório).
  def create(conn, params) do
    with_admin_scope(conn, fn scope ->
      case Directory.create_clinic_professional(scope, input(params)) do
        {:ok, prof} ->
          conn |> put_status(:created) |> json(%{professional: prof_json(prof)})

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # PATCH /api/professionals/:id — atualização parcial da ficha.
  def update(conn, %{"id" => id} = params) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Directory.update_clinic_professional(scope, &1, input(params)))
    end)
  end

  # POST /api/professionals/:id/deactivate — arquiva (some da lista de ativos, sem apagar).
  def deactivate(conn, %{"id" => id}) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Directory.deactivate_clinic_professional(scope, &1))
    end)
  end

  # POST /api/professionals/:id/reactivate — reativa.
  def reactivate(conn, %{"id" => id}) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Directory.reactivate_clinic_professional(scope, &1))
    end)
  end

  # PATCH /api/professionals/:id/hours — substitui a grade dos dias enviados (valida a semana
  # inteira antes de escrever, incluindo o invariante prof ⊆ clínica).
  def update_hours(conn, %{"id" => id} = params) do
    with_admin_scope(conn, fn scope ->
      days = params |> Map.get("days", []) |> Enum.map(&day_input/1)

      case Scheduling.update_professional_hours(scope, id, days) do
        {:ok, rows} ->
          json(conn, %{hours: Enum.map(rows, &hours_row_json/1)})

        {:error, :professional_not_in_clinic} ->
          not_found(conn)

        {:error, {:invalid, details}} ->
          unprocessable(conn, details)

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # POST /api/professionals/:id/exceptions — folga ou horário pontual do profissional.
  def create_exception(conn, %{"id" => id} = params) do
    with_admin_scope(conn, fn scope ->
      case Scheduling.create_professional_exception(scope, id, exception_input(params)) do
        {:ok, exc} ->
          conn |> put_status(:created) |> json(%{exception: exception_json(exc)})

        {:error, :professional_not_in_clinic} ->
          not_found(conn)

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # DELETE /api/professionals/:id/exceptions/:exception_id — apaga (destroy de verdade). A
  # exceção precisa ser DESTE profissional (o `:id` do path): uma de outro dono, ou uma exceção
  # da clínica (professional_id nulo), é indistinguível de inexistente → 404. Sem essa amarração,
  # o endpoint do profissional apagaria feriado da clínica ou folga de terceiro (bate-volta).
  def delete_exception(conn, %{"id" => professional_id, "exception_id" => exception_id}) do
    with_admin_scope(conn, fn scope ->
      case Scheduling.fetch_professional_exception(scope, exception_id) do
        {:ok, %{professional_id: ^professional_id} = exc} ->
          case Scheduling.destroy_professional_exception(scope, exc) do
            :ok -> send_resp(conn, :no_content, "")
            {:error, error} -> error_response(conn, error)
          end

        _ ->
          not_found(conn)
      end
    end)
  end

  # ---- helpers ----

  # Busca-e-escreve: as mutações por id compartilham a mesma escada (404 se não existe ou é de
  # outra clínica; 422 se a ação recusa).
  defp write(conn, scope, id, fun) do
    with {:ok, %{} = prof} <- Directory.fetch_clinic_professional(scope, id),
         {:ok, updated} <- fun.(prof) do
      json(conn, %{professional: prof_json(updated)})
    else
      {:ok, nil} -> not_found(conn)
      {:error, error} -> error_response(conn, error)
    end
  end

  # `clinic_id` NÃO sai: é o tenant, já implícito na sessão. `weekly_hours`/`exceptions` só saem
  # quando carregados (lista traz a grade; a ficha traz também as exceções).
  defp prof_json(p, opts \\ []) do
    base = %{
      id: p.id,
      nome: p.nome,
      nome_exibicao: p.nome_exibicao,
      nascimento: p.nascimento,
      cpf: p.cpf,
      rg: p.rg,
      estado_civil: p.estado_civil,
      tel: p.tel,
      email: p.email,
      cep: p.cep,
      endereco: p.endereco,
      numero: p.numero,
      complemento: p.complemento,
      bairro: p.bairro,
      cidade: p.cidade,
      uf: p.uf,
      emergencia_nome: p.emergencia_nome,
      emergencia_tel: p.emergencia_tel,
      profissao: p.profissao,
      crefito: p.crefito,
      registro_uf: p.registro_uf,
      ano_conclusao: p.ano_conclusao,
      especialidades: p.especialidades,
      sub: p.sub,
      vinculo: p.vinculo,
      razao_social: p.razao_social,
      cnpj: p.cnpj,
      banco: p.banco,
      agencia: p.agencia,
      conta: p.conta,
      conta_tipo: p.conta_tipo,
      pix: p.pix,
      cor_indice: p.cor_indice,
      segue_horario_clinica: p.segue_horario_clinica,
      ativo: p.ativo
    }

    base
    |> maybe_put_loaded(:weekly_hours, p.weekly_hours, &hours_row_json/1)
    |> then(fn map ->
      if Keyword.get(opts, :exceptions, false),
        do: maybe_put_loaded(map, :exceptions, p.exceptions, &exception_json/1),
        else: map
    end)
  end

  defp maybe_put_loaded(map, _key, %Ash.NotLoaded{}, _fun), do: map

  defp maybe_put_loaded(map, key, list, fun) when is_list(list),
    do: Map.put(map, key, Enum.map(list, fun))

  defp maybe_put_loaded(map, _key, _other, _fun), do: map

  defp hours_row_json(row), do: %{dow: row.dow, modo: mode_of(row), periods: row.periods}

  # `ClinicHours` não tem `modo` (é sempre o expediente); `ProfessionalHours` tem. Um único
  # shape no JSON simplifica o front (que sempre recebe `{dow, modo, periods}`).
  defp mode_of(%Api.Scheduling.ProfessionalHours{modo: modo}), do: modo
  defp mode_of(_), do: nil

  defp exception_json(e),
    do: %{id: e.id, data: e.data, nome: e.nome, tipo: e.tipo, periods: e.periods}

  @campos ~w(nome nome_exibicao nascimento cpf rg estado_civil tel email cep endereco numero
             complemento bairro cidade uf emergencia_nome emergencia_tel profissao crefito
             registro_uf ano_conclusao especialidades sub vinculo razao_social cnpj banco
             agencia conta conta_tipo pix cor_indice segue_horario_clinica)a

  # `clinic_id` e `ativo` (só muda por deactivate/reactivate) são ignorados pela whitelist.
  defp input(params), do: whitelist(params, @campos)

  # Um dia da grade vindo do corpo → mapa de chaves atom; `modo`/`periods` são validados no
  # domínio (a coerção do enum e a checagem prof ⊆ clínica moram lá).
  defp day_input(day) when is_map(day) do
    %{
      dow: day["dow"],
      modo: day["modo"],
      periods: day["periods"] || []
    }
  end

  defp exception_input(params), do: whitelist(params, ~w(data nome tipo periods)a)
end
