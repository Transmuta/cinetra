defmodule ApiWeb.PatientsController do
  @moduledoc """
  Cadastro de pacientes da clínica (fatia Pacientes). Espelha `ProfessionalsController`: lê o
  `Api.Scope` do request, chama os code interfaces do domínio com `scope:` e monta o JSON. O
  `clinic_id` vem **sempre** do escopo, nunca do corpo (09 §8). RBAC ADR-016: **leitura** (GET)
  liberada a qualquer membro ativo; **escrita** exige owner/admin.

  Endpoints — a ficha inteira num corpo só (o form do protótipo é uma tela única):

    * `GET/POST /patients`, `GET/PATCH /patients/:id`;
    * `POST /patients/:id/deactivate|reactivate` (arquivar, não apagar).

  Pacotes, histórico e anexos da ficha do protótipo não têm endpoint aqui: os recursos que os
  alimentam (F1/F3/v2) ainda não existem — a ficha do web degrada sem eles.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Records

  # GET /api/patients — uma PÁGINA, já filtrada e buscada no servidor (`?q=`, `?filter=`,
  # `?limit=`, `?offset=`). As contagens da sidebar vão junto porque, paginado, o cliente não
  # tem como contar os segmentos.
  def index(conn, params) do
    with_member_scope(conn, fn scope ->
      page = Records.list_clinic_patients(scope, list_opts(params))

      json(conn, %{
        patients: Enum.map(page.results, &patient_json/1),
        page: %{limit: page.limit, offset: page.offset, total: page.count, more: page.more?},
        counts: Records.clinic_patient_counts(scope)
      })
    end)
  end

  # GET /api/patients/:id — a ficha completa.
  #
  # `faltas` é pedido **aqui e só aqui**: é o stat do cabeçalho da ficha (doc 51 §L3). O agregado
  # vira um `LEFT JOIN LATERAL` sobre `attendances`, e o mesmo lookup serve o histórico, os anexos
  # e as escritas — nenhum deles lê o número.
  def show(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      case Records.fetch_clinic_patient(scope, id, load: [:faltas]) do
        {:ok, %{} = patient} -> json(conn, %{patient: patient_json(patient)})
        {:ok, nil} -> not_found(conn)
      end
    end)
  end

  # GET /api/patients/:patient_id/history — as sessões do paciente (C13, Frente 7).
  #
  # Sai daqui, e não do `AppointmentsController`, porque a pergunta é da FICHA ("o que aconteceu
  # com este paciente?"), não da agenda ("o que acontece neste dia?") — e a resposta é por
  # PRESENÇA: numa turma o bloco pode estar concluído com a presença dele faltando.
  #
  # Devolve DUAS listas (doc 56): `sessions` é o histórico (paginável por `?limit=`/`?offset=`) e
  # `upcoming` é o que ainda vai acontecer. A rota continua uma só porque a ficha quer as duas na
  # mesma abertura, e o domínio as lê na mesma transação — separar em dois endpoints trocaria uma
  # query barata por um round-trip.
  def history(conn, %{"patient_id" => patient_id} = params) do
    with_member_scope(conn, fn scope ->
      # Resolve o paciente ANTES — pela mesma porta do `show/2`, que já trata id malformado como
      # inexistente (`{:ok, nil}` → 404). Sem isto, um id de outra clínica (ou lixo) devolvia
      # **200 com lista vazia**: o mesmo sucesso silencioso que a massa por pacote corrigiu.
      case Records.fetch_clinic_patient(scope, patient_id) do
        {:ok, %{id: id}} ->
          %{
            sessions: sessions,
            more?: more?,
            upcoming: upcoming,
            upcoming_more?: upcoming_more?
          } =
            Api.Scheduling.list_patient_sessions(scope, id,
              limit: parse_int(params["limit"]),
              offset: parse_int(params["offset"])
            )

          json(conn, %{
            sessions: Enum.map(sessions, &session_json/1),
            more: more?,
            upcoming: Enum.map(upcoming, &session_json/1),
            upcoming_more: upcoming_more?
          })

        {:ok, nil} ->
          not_found(conn)
      end
    end)
  end

  defp session_json(attendance) do
    appt = attendance.appointment

    %{
      id: attendance.id,
      status: attendance.status,
      falta_justificada: attendance.falta_justificada,
      package_id: attendance.package_id,
      appointment_id: appt.id,
      starts_at: DateTime.to_iso8601(appt.starts_at),
      ends_at: DateTime.to_iso8601(appt.ends_at),
      appointment_status: appt.status,
      obs: appt.obs,
      tipo: appt.appointment_type && appt.appointment_type.nome,
      cor: appt.appointment_type && appt.appointment_type.cor,
      profissional:
        appt.professional && (appt.professional.nome_exibicao || appt.professional.nome)
    }
  end

  # POST /api/patients — cria a ficha (só o nome é obrigatório).
  def create(conn, params) do
    with_admin_scope(conn, fn scope ->
      case Records.create_clinic_patient(scope, input(params)) do
        {:ok, patient} ->
          conn |> put_status(:created) |> json(%{patient: patient_json(patient)})

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # PATCH /api/patients/:id — atualização parcial da ficha.
  def update(conn, %{"id" => id} = params) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Records.update_clinic_patient(scope, &1, input(params)))
    end)
  end

  # POST /api/patients/:id/deactivate — arquiva (some da lista de ativos, sem apagar).
  def deactivate(conn, %{"id" => id}) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Records.deactivate_clinic_patient(scope, &1))
    end)
  end

  # POST /api/patients/:id/reactivate — reativa.
  def reactivate(conn, %{"id" => id}) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Records.reactivate_clinic_patient(scope, &1))
    end)
  end

  # ---- helpers ----

  # Query string → opções da listagem. Valor inválido vira `nil` e o DOMÍNIO aplica o default
  # (a lista nunca quebra por causa de um `?limit=abc`) — repetir o 50 aqui só criaria dois
  # lugares para mudar. Tetos de limit/offset também são do domínio.
  defp list_opts(params) do
    [
      q: params["q"],
      status: parse_status(params["filter"]),
      limit: parse_int(params["limit"]),
      offset: parse_int(params["offset"])
    ]
  end

  # `to_existing_atom` só depois do guard da whitelist — nunca converte entrada crua em átomo.
  defp parse_status(status) when status in ~w(ativos inativos resp),
    do: String.to_existing_atom(status)

  defp parse_status(_), do: :todos

  # Busca-e-escreve: as mutações por id compartilham a mesma escada (404 se não existe ou é de
  # outra clínica; 422 se a ação recusa).
  defp write(conn, scope, id, fun) do
    with {:ok, %{} = patient} <- Records.fetch_clinic_patient(scope, id),
         {:ok, updated} <- fun.(patient) do
      json(conn, %{patient: patient_json(updated)})
    else
      {:ok, nil} -> not_found(conn)
      {:error, error} -> error_response(conn, error)
    end
  end

  # `clinic_id` NÃO sai: é o tenant, já implícito na sessão.
  defp patient_json(p) do
    %{
      id: p.id,
      nome: p.nome,
      nome_social: p.nome_social,
      cpf: p.cpf,
      rg: p.rg,
      genero: p.genero,
      estado_civil: p.estado_civil,
      nascimento: p.nascimento,
      responsavel: p.responsavel,
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
      emergencia_parentesco: p.emergencia_parentesco,
      emergencia_tel: p.emergencia_tel,
      profissao: p.profissao,
      empresa: p.empresa,
      atend_tipo: p.atend_tipo,
      convenio: p.convenio,
      carteirinha: p.carteirinha,
      convenio_validade: p.convenio_validade,
      medico: p.medico,
      crm: p.crm,
      como_conheceu: p.como_conheceu,
      prefs: p.prefs,
      tags: p.tags,
      lgpd: p.lgpd,
      comunicacao: p.comunicacao,
      cor_indice: p.cor_indice,
      ativo: p.ativo,
      faltas: faltas(p)
    }
  end

  # `nil` quando o agregado não foi carregado — é o caso da LISTA, onde um `count` por linha
  # sairia caro e ninguém pede o número. Sem esta cláusula, o `%Ash.NotLoaded{}` chegaria ao
  # encoder e derrubaria a resposta inteira.
  defp faltas(%{faltas: n}) when is_integer(n), do: n
  defp faltas(_patient), do: nil

  @campos ~w(nome nome_social cpf rg genero estado_civil nascimento responsavel tel email cep
             endereco numero complemento bairro cidade uf emergencia_nome emergencia_parentesco
             emergencia_tel profissao empresa atend_tipo convenio carteirinha convenio_validade
             medico crm como_conheceu prefs tags lgpd comunicacao cor_indice)a

  # `clinic_id` e `ativo` (só muda por deactivate/reactivate) são ignorados pela whitelist.
  defp input(params), do: whitelist(params, @campos)
end
