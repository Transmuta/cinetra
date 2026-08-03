defmodule ApiWeb.AgendaChannelMetricasTest do
  @moduledoc """
  **M6 (doc 101)** — a instrumentação da amplificação do tempo real.

  O plano da onda 3 decidiu **não mexer** no desenho (a releitura por assinante é o que faz o
  recorte A7 valer no WebSocket com uma autoridade só) e **medir antes**. Este teste prende os
  sinais que produzem o número, porque instrumentação é o tipo de código que falha em silêncio:
  o evento deixa de ser emitido, a série fica reta em zero, e uma linha reta lê-se como saúde.

  O que ele afirma:

    * publicar emite **um** broadcast por tópico afetado (dia e mês);
    * o canal em modo `block` emite entrega **com** releitura, e a releitura tem duração medida;
    * o canal em modo `signal` emite entrega **sem** releitura — é a metade que não paga banco, e
      contá-la junto com a outra apagaria o único número que interessa;
    * a razão entregas/broadcast é a amplificação, e ela cresce com o número de assinantes.
  """
  use ApiWeb.ChannelCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling
  alias Api.Scheduling.AgendaNotifier
  alias ApiWeb.AgendaChannel

  @dia "2026-07-20"

  defp fixture do
    owner = sign_in!(email_unico("m6"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    prof =
      Directory.create_professional!("Dra. X", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    tipo =
      Directory.create_appointment_type!(
        %{
          nome: "Sessão #{System.unique_integer([:positive])}",
          duracao_minutos: 50,
          cor: "#0FB5A6",
          icon: "Activity"
        },
        tenant: clinic.id,
        actor: owner
      )

    paciente =
      Records.create_patient!("Paciente", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    %{owner: owner, clinic: clinic, prof: prof, tipo: tipo, paciente: paciente}
  end

  defp socket_for(user, clinic) do
    Phoenix.ChannelTest.socket(ApiWeb.UserSocket, "user_socket:#{user.id}", %{
      user_id: user.id,
      clinic_id: clinic.id
    })
  end

  defp dia_topic(clinic), do: "clinic:#{clinic.id}:agenda:#{@dia}"
  defp mes_topic(clinic), do: "clinic:#{clinic.id}:agenda:month:2026-07"

  # Escuta os três eventos e devolve o que caiu, na ordem.
  defp escutando(fun) do
    parent = self()
    ref = make_ref()

    eventos = [
      AgendaNotifier.evento_broadcast(),
      AgendaChannel.evento_entrega(),
      AgendaChannel.evento_releitura()
    ]

    :telemetry.attach_many(
      {__MODULE__, ref},
      eventos,
      fn evento, medidas, meta, _ -> send(parent, {ref, evento, medidas, meta}) end,
      nil
    )

    fun.()

    coletados = drenar(ref, [])
    :telemetry.detach({__MODULE__, ref})
    coletados
  end

  defp drenar(ref, acc) do
    receive do
      {^ref, evento, medidas, meta} -> drenar(ref, acc ++ [{evento, medidas, meta}])
    after
      200 -> acc
    end
  end

  defp conta(coletados, evento), do: Enum.count(coletados, &(elem(&1, 0) == evento))

  defp agendar(ctx) do
    Scheduling.schedule_appointment(
      %{
        starts_at: "2026-07-20T11:00:00Z",
        professional_id: ctx.prof.id,
        appointment_type_id: ctx.tipo.id,
        patient_ids: [ctx.paciente.id]
      },
      scope: escopo(ctx.owner, ctx.clinic)
    )
  end

  test "publicar emite um broadcast por tópico afetado (dia e mês)" do
    ctx = fixture()

    coletados = escutando(fn -> {:ok, _} = agendar(ctx) end)

    assert conta(coletados, AgendaNotifier.evento_broadcast()) == 2
  end

  test "o canal em `block` entrega COM releitura, e a releitura tem duração medida" do
    ctx = fixture()

    {:ok, _, _} =
      ctx.owner
      |> socket_for(ctx.clinic)
      |> subscribe_and_join(AgendaChannel, dia_topic(ctx.clinic))

    coletados = escutando(fn -> {:ok, _} = agendar(ctx) end)

    entregas =
      Enum.filter(coletados, fn {evento, _, meta} ->
        evento == AgendaChannel.evento_entrega() and meta.modo == "block"
      end)

    assert [{_, %{count: 1}, %{releitura: "true"}}] = entregas

    assert [{_, %{duration: duration}, %{achou: "true"}}] =
             Enum.filter(coletados, &(elem(&1, 0) == AgendaChannel.evento_releitura()))

    assert duration > 0
  end

  # A metade que NÃO paga banco. Sem o rótulo, ela entraria na mesma conta das releituras e o
  # número que decide a ação (quantas leituras por escrita) viria inflado.
  test "o canal em `signal` entrega SEM releitura" do
    ctx = fixture()

    {:ok, _, _} =
      ctx.owner
      |> socket_for(ctx.clinic)
      |> subscribe_and_join(AgendaChannel, mes_topic(ctx.clinic))

    coletados = escutando(fn -> {:ok, _} = agendar(ctx) end)

    assert [{_, %{count: 1}, %{modo: "signal", releitura: "false"}}] =
             Enum.filter(coletados, &(elem(&1, 0) == AgendaChannel.evento_entrega()))

    assert conta(coletados, AgendaChannel.evento_releitura()) == 0
  end

  # É esta razão que o painel divide: dois assinantes do mesmo dia, uma escrita, DUAS releituras.
  # Se um dia o desenho mudar para leitura compartilhada, é aqui que a mudança aparece.
  test "a amplificação é entregas/broadcast — dois assinantes, duas releituras" do
    ctx = fixture()
    {outro, _} = convite_aceito!(ctx.owner, ctx.clinic, :recepcao)

    for user <- [ctx.owner, outro] do
      {:ok, _, _} =
        user |> socket_for(ctx.clinic) |> subscribe_and_join(AgendaChannel, dia_topic(ctx.clinic))
    end

    coletados = escutando(fn -> {:ok, _} = agendar(ctx) end)

    assert conta(coletados, AgendaNotifier.evento_broadcast()) == 2
    assert conta(coletados, AgendaChannel.evento_releitura()) == 2
  end
end
