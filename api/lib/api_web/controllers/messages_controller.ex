defmodule ApiWeb.MessagesController do
  @moduledoc """
  A comunicação com o paciente na fronteira (doc 52 §6): a **timeline** de um agendamento e o
  disparo manual.

  ## A timeline devolve mais do que a tabela tem

  Uma linha por participante, e a de quem **não** recebeu nada não vem de `Message` — vem do
  `Dispatch.avaliar/2`, que responde por quê (§6/§10.3). É deliberado: a mesma regra que decide o
  envio explica o silêncio, e é isso que impede a tela de dizer "sem e-mail" enquanto o e-mail
  sai.

  Silêncio na tela seria pior do que não ter a funcionalidade: a recepção passaria a supor que a
  mensagem saiu.

  ## Quem pode disparar

  Os mesmos papéis que agendam (`owner`·`admin`·`recepcao`·`profissional`). Não é a policy do
  recurso porque a escrita de `Message` é de sistema — quem guarda é a fronteira, e o
  `disparado_por_id` registra quem foi.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Messaging
  alias Api.Messaging.Dispatch
  alias Api.Messaging.Templates

  @papeis_que_disparam [:owner, :admin, :recepcao, :profissional]

  # GET /api/appointments/:appointment_id/messages
  def index(conn, %{"appointment_id" => appointment_id}) do
    with_member_scope(conn, fn scope ->
      case timeline(scope, appointment_id) do
        {:ok, payload} -> json(conn, payload)
        :error -> not_found(conn)
      end
    end)
  end

  # POST /api/appointments/:appointment_id/messages
  #
  # Envia (ou reenvia) a confirmação. `patient_id` opcional recorta um participante — numa turma,
  # reenviar para quem falhou não pode disparar para os outros três.
  def create(conn, %{"appointment_id" => appointment_id} = params) do
    with_roles_scope(conn, @papeis_que_disparam, fn scope ->
      case disparar(scope, appointment_id, params["patient_id"]) do
        {:ok, resultados} ->
          conn |> put_status(:created) |> json(%{resultados: resultados})

        :error ->
          not_found(conn)
      end
    end)
  end

  # ---- timeline ----

  defp timeline(scope, appointment_id) do
    case carregar(scope, appointment_id) do
      {:ok, clinic, participantes} ->
        mensagens = Enum.group_by(Messaging.timeline(scope, appointment_id), & &1.attendance_id)

        {:ok,
         %{
           participantes:
             Enum.map(participantes, &linha_do_participante(&1, clinic, mensagens[&1.id] || []))
         }}

      :error ->
        :error
    end
  end

  defp linha_do_participante(attendance, clinic, mensagens) do
    %{
      attendanceId: attendance.id,
      patientId: attendance.patient_id,
      paciente: attendance.patient.nome,
      mensagens: Enum.map(mensagens, &serializar/1),
      # A explicação do silêncio (§6). Só faz sentido quando não há mensagem nenhuma: depois de
      # uma tentativa, o que a recepção precisa ler é o estado dela, não o motivo hipotético.
      semEnvio: if(mensagens == [], do: motivo_sem_envio(attendance.patient, clinic))
    }
  end

  defp motivo_sem_envio(patient, clinic) do
    case Dispatch.avaliar(patient, clinic_id: clinic.id) do
      {:skip, motivo} -> to_string(motivo)
      {:ok, _canal, _destino} -> nil
    end
  end

  defp serializar(message) do
    %{
      id: message.id,
      canal: message.canal,
      kind: message.kind,
      status: message.status,
      destino: message.destino,
      erro: message.erro,
      resposta: message.resposta,
      # Nulo = automático. É a distinção que a recepção usa para saber se precisa fazer algo (§6).
      automatico: is_nil(message.disparado_por_id),
      enfileiradoEm: message.enfileirado_em,
      enviadoEm: message.enviado_em,
      entregueEm: message.entregue_em,
      lidoEm: message.lido_em,
      falhouEm: message.falhou_em,
      respondidoEm: message.respondido_em,
      # O texto vem do template + vars gravados, renderizado na leitura — o corpo não é
      # persistido (§4, retenção).
      titulo: titulo(message)
    }
  end

  defp titulo(message) do
    case Templates.render_email(message.template, message.vars) do
      {:ok, %{assunto: assunto}} -> assunto
      :error -> to_string(message.kind)
    end
  end

  # ---- disparo ----

  defp disparar(scope, appointment_id, patient_id) do
    case carregar(scope, appointment_id) do
      {:ok, clinic, participantes} ->
        {:ok,
         participantes
         |> filtrar(patient_id)
         |> Enum.map(&resultado(clinic, &1, scope))}

      :error ->
        :error
    end
  end

  defp filtrar(participantes, nil), do: participantes

  defp filtrar(participantes, patient_id),
    do: Enum.filter(participantes, &(&1.patient_id == patient_id))

  defp resultado(clinic, attendance, scope) do
    case Dispatch.dispatch(clinic, attendance, attendance.patient, :confirmacao,
           disparado_por_id: scope.user.id
         ) do
      {:ok, message} -> %{patientId: attendance.patient_id, enviado: true, messageId: message.id}
      {:skip, motivo} -> %{patientId: attendance.patient_id, enviado: false, motivo: motivo}
    end
  end

  # O agendamento com participantes vivos e a clínica. Lido **sob o escopo** (não
  # `authorize?: false`): é isso que faz um profissional não alcançar bloco de coluna alheia, e
  # faz agendamento de outra clínica responder 404 em vez de vazar existência.
  defp carregar(scope, appointment_id) do
    Api.Tenancy.in_clinic(scope, fn ->
      # `load:` na própria code interface, e não um `Ash.load!` depois: a rule do projeto
      # (`.claude/rules/ash.md`) proíbe `Ash.get!`/`Ash.load!` em controller pelo mesmo motivo que
      # `Repo.get` fora de contexto — e aqui há um ganho concreto, a leitura vira uma só.
      with {:ok, appointment} <-
             Api.Scheduling.get_appointment(appointment_id,
               scope: scope,
               load: [attendances: [:patient]],
               not_found_error?: false
             ),
           false <- is_nil(appointment) do
        clinic = Api.Accounts.get_clinic!(scope.clinic_id, authorize?: false)

        participantes = Enum.filter(appointment.attendances, &Api.Scheduling.Attendance.viva?/1)

        {:ok, clinic, participantes}
      else
        _ -> :error
      end
    end)
  end
end
