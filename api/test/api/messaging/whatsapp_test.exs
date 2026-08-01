defmodule Api.Messaging.WhatsAppTest do
  @moduledoc """
  O canal de WhatsApp ponta a ponta dentro do sistema (doc 65 §2): escolha de canal, render do
  template, o que chega ao transporte e o que acontece quando a Meta recusa.

  Fala com `Api.Messaging.WhatsAppMemory`, não com a Zernio — a suíte não pode depender de um
  terceiro estar de pé (mesma razão do `Api.Storage.Memory`).
  """
  use Api.DataCase, async: false

  alias Api.Messaging
  alias Api.Messaging.SendJob
  alias Api.Messaging.Transport
  alias Api.Messaging.WhatsAppMemory

  setup do
    anterior = Application.get_env(:api, Api.Messaging.Transport, [])

    Application.put_env(
      :api,
      Api.Messaging.Transport,
      Keyword.put(anterior, :whatsapp_habilitado, true)
    )

    WhatsAppMemory.limpar()

    on_exit(fn ->
      Application.put_env(:api, Api.Messaging.Transport, anterior)
      WhatsAppMemory.limpar()
    end)

    :ok
  end

  describe "Transport.disponivel?/1 — o interruptor E a credencial" do
    test "ligado com adapter configurado, o canal existe" do
      assert Transport.disponivel?(:whatsapp)
    end

    test "desligado, não existe — mesmo com credencial" do
      # É o freio de mão do §9: suspender o canal sem tirar chave de lugar nenhum.
      atual = Application.get_env(:api, Api.Messaging.Transport, [])

      Application.put_env(
        :api,
        Api.Messaging.Transport,
        Keyword.put(atual, :whatsapp_habilitado, false)
      )

      refute Transport.disponivel?(:whatsapp)
    end

    test "ligado sem adapter configurado, também não existe" do
      # Sem esta metade, um WHATSAPP_HABILITADO=true esquecido num ambiente sem credencial faria
      # TODA mensagem nascer `:falhou` em vez de sair pelo e-mail de reserva.
      atual = Application.get_env(:api, Api.Messaging.Transport, [])

      Application.put_env(
        :api,
        Api.Messaging.Transport,
        Keyword.put(atual, :whatsapp_adapter, Api.Messaging.Zernio)
      )

      refute Transport.disponivel?(:whatsapp)
    end
  end

  describe "o envio, do agendamento ao transporte" do
    test "a confirmação sai pelo WhatsApp, com template e parâmetros na ordem" do
      ctx = clinica(whatsapp: true)

      paciente =
        paciente_com(ctx, nome: "Ana Maria Souza", comunicacao: true, tel: "(11) 98765-4321")

      message = confirmacao!(ctx, paciente)

      assert message.canal == :whatsapp
      assert message.destino == "+5511987654321"

      assert :ok = SendJob.perform(job(message))

      assert [envio] = WhatsAppMemory.enviadas()
      assert envio.destino == "+5511987654321"
      assert envio.template == "confirmacao_v1"
      assert envio.idioma == "pt_BR"

      # [primeiro nome, clínica, data, hora, telefone da clínica, token do botão]
      assert [nome, clinica, _data, _hora, telefone, token] = envio.params
      assert nome == "Ana"
      assert clinica == ctx.clinic.nome

      # O telefone atravessa a fronteira inteira: coluna da clínica → `vars` da mensagem →
      # posicional do template. É a única saída de voz que o canal oferece — o botão é URL e não
      # trafega nada de volta pelo WhatsApp.
      assert telefone == ctx.clinic.telefone

      # O token é o SUFIXO da URL, não a URL: o domínio está congelado no botão aprovado.
      refute token =~ "http"
      assert Api.Messaging.ReplyToken.verify(token) == {:ok, message.id}
    end

    test "a entrega roda FORA da transação da GUC" do
      # O bate-volta do doc 60 tirou o I/O externo de dentro da transação (conexão do pool presa
      # `idle in transaction` pelo tempo da rede alheia) e não deixou instrumento — o WhatsApp
      # entrou pelo mesmo caminho, e sem isto a correção se desfaz sem ninguém ver.
      #
      # `mix test` roda sem sandbox de transação por processo aqui (`async: false`), então
      # `in_transaction?` só é verdadeiro se **alguém acima** abriu uma: exatamente o que a
      # correção proíbe.
      ctx = clinica(whatsapp: true)
      paciente = paciente_com(ctx, comunicacao: true, tel: "11987654321")
      message = confirmacao!(ctx, paciente)

      SendJob.perform(job(message))

      assert [%{em_transacao?: false}] = WhatsAppMemory.enviadas()
    end

    test "o id do provider é gravado — é a chave que o webhook usa depois" do
      ctx = clinica(whatsapp: true)
      paciente = paciente_com(ctx, comunicacao: true, tel: "11987654321")
      message = confirmacao!(ctx, paciente)

      SendJob.perform(job(message))

      recarregada = recarregar_mensagem(ctx, message)
      assert recarregada.status == :enviado
      assert recarregada.provider == "zernio"
      assert recarregada.provider_message_id =~ "wamid-"
    end

    test "recusa da Meta vira falha legível na tela, e o job NÃO retenta" do
      # Erro de negócio (número inválido) falharia igual nas três tentativas; o retry existe para
      # erro de rede, que o transporte levanta.
      WhatsAppMemory.falhar_com("400 131021: Recipient is not a valid WhatsApp user")

      ctx = clinica(whatsapp: true)
      paciente = paciente_com(ctx, comunicacao: true, tel: "11987654321")
      message = confirmacao!(ctx, paciente)

      assert :ok = SendJob.perform(job(message))

      recarregada = recarregar_mensagem(ctx, message)
      assert recarregada.status == :falhou

      assert Messaging.Falhas.para_tela(recarregada.erro) ==
               "Este número não tem WhatsApp — confira o telefone na ficha"
    end

    test "a conta pela qual a clínica fala viaja na mensagem" do
      # §9.1.4: o número é configuração por clínica desde já, para "a clínica nº 2 quer o número
      # dela" ser um UPDATE. E é histórico: "mandamos deste número" não pode mudar depois.
      ctx = clinica(whatsapp: true)

      Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
        ctx.clinic
        |> Ash.Changeset.for_update(:update_settings, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:zernio_account_id, "conta-da-clinica")
        |> Ash.update!()
      end)

      paciente = paciente_com(ctx, comunicacao: true, tel: "11987654321")
      message = confirmacao!(ctx, paciente)

      SendJob.perform(job(message))

      assert [%{conta: "conta-da-clinica"}] = WhatsAppMemory.enviadas()
    end
  end

  # Marca a sessão e dispara a confirmação **à mão**, como a recepção faz pelo botão do drawer.
  # Era a criação do bloco que produzia esta mensagem sozinha; desde 2026-07-31 (doc 98) ela não
  # produz mais, e o que este arquivo mede — canal, template, transporte — não mudou.
  # A clínica é **relida** do banco, e não reaproveitada do `ctx`: o teste da conta de WhatsApp
  # grava `zernio_account_id` depois de montar o contexto, e a struct antiga não o traz — o
  # `Dispatch` congelaria a mensagem sem a conta. É o que o notifier já fazia por dentro.
  defp confirmacao!(ctx, paciente) do
    appt = agendamento!(ctx, paciente: paciente)
    [presenca] = appt.attendances

    clinic =
      Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
        Api.Accounts.get_clinic!(ctx.clinic.id, authorize?: false)
      end)

    {:ok, message} = Messaging.Dispatch.dispatch(clinic, presenca, paciente, :confirmacao)

    message
  end

  defp job(message),
    do: %Oban.Job{args: %{"clinic_id" => message.clinic_id, "message_id" => message.id}}
end
