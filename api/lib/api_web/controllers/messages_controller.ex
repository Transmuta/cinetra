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

  `owner`·`admin`·`recepcao`·`profissional`. Não é a policy do recurso porque a escrita de
  `Message` é de sistema — quem guarda é a fronteira, e o `disparado_por_id` registra quem foi.

  Esta lista **era** descrita como "os mesmos papéis que agendam", e deixou de ser em 2026-08-04
  (doc 103): o `profissional` saiu do agendar e continua aqui, de propósito. A matriz de acesso
  sempre tratou comunicação como célula própria (`:propria` — ele fala nos próprios atendimentos),
  e a decisão daquele dia foi sobre a agenda. Se um dia a comunicação for reavaliada, é aqui e na
  linha `comunicacao` de `Api.Accounts.AccessMatrix` que ela muda — não por arrasto.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Messaging
  alias Api.Messaging.Dispatch
  alias Api.Messaging.Falhas
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
        # 201 só quando alguma mensagem de fato nasceu. Se todos os participantes caíram em
        # `{:skip, motivo}` — já confirmou, opt-out, sem canal — nenhuma `Message` foi criada, e
        # `201 Created` afirmava uma criação que não houve (doc 96, H-9).
        {:ok, resultados} ->
          status = if Enum.any?(resultados, &(&1[:status] != :skip)), do: :created, else: :ok
          conn |> put_status(status) |> json(%{resultados: resultados})

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
      attendance_id: attendance.id,
      patient_id: attendance.patient_id,
      paciente: attendance.patient.nome,
      mensagens: Enum.map(mensagens, &serializar/1),
      # A explicação do silêncio (§6). Só faz sentido quando não há mensagem nenhuma: depois de
      # uma tentativa, o que a recepção precisa ler é o estado dela, não o motivo hipotético.
      sem_envio: if(mensagens == [], do: motivo_sem_envio(attendance.patient, clinic))
    }
  end

  defp motivo_sem_envio(patient, clinic) do
    case Dispatch.avaliar(patient, clinic: clinic) do
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
      # Os dois: o cru fica para o suporte investigar, o traduzido é o que a tela mostra. O
      # provider fala inglês técnico, e quem lê a timeline é a recepção no balcão — texto em
      # inglês ali não informa, gera chamado (`Api.Messaging.Falhas`).
      erro: message.erro,
      erro_texto: Falhas.para_tela(message.erro),
      resposta: message.resposta,
      # Nulo = automático. É a distinção que a recepção usa para saber se precisa fazer algo (§6).
      automatico: is_nil(message.disparado_por_id),
      enfileirado_em: message.enfileirado_em,
      # Preenchido só quando a janela de silêncio adiou (§7). É o que separa "na fila" de "não
      # saiu": sem ele a tela mostra uma mensagem parada e ninguém sabe se ela ainda vai sair.
      agendado_para: message.agendado_para,
      enviado_em: message.enviado_em,
      entregue_em: message.entregue_em,
      lido_em: message.lido_em,
      falhou_em: message.falhou_em,
      # A retirada da fila (§7 + doc 40): o bloco foi cancelado ou excluído enquanto a mensagem
      # esperava a janela de silêncio abrir. O motivo viaja porque "Não enviada" sozinho manda a
      # recepção procurar um defeito onde houve uma decisão.
      descartada_em: message.descartada_em,
      descarte_motivo: message.descarte_motivo,
      respondido_em: message.respondido_em,
      # O texto vem do template + vars gravados, renderizado na leitura — o corpo não é
      # persistido (§4, retenção).
      titulo: titulo(message)
    }
  end

  defp titulo(message) do
    case Templates.assunto(message.template, message.vars) do
      {:ok, assunto} -> assunto
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
      {:ok, message} ->
        %{
          patient_id: attendance.patient_id,
          enviado: true,
          message_id: message.id,
          # A janela de silêncio (§7) adiou: o pedido foi aceito e a mensagem NÃO sai agora.
          # Sem isto a tela diria "Mensagem enviada" para algo que ainda está na fila — o mesmo
          # "Feito" que não enviava, com outra causa.
          agendado_para: message.agendado_para
        }

      {:skip, motivo} ->
        %{patient_id: attendance.patient_id, enviado: false, motivo: motivo}
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
