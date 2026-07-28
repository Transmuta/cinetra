defmodule Api.Messaging.DispatchTest do
  @moduledoc """
  O `Dispatch` é o único lugar que decide se uma mensagem sai (doc 52 §10.3), então é aqui que a
  regra inteira precisa estar provada: consentimento, destino, opt-out, ordem de canal e a janela
  de silêncio.

  O teste que mais importa é o do §10.4 — *opt-out não cai para a reserva*. Ele é a diferença
  entre respeitar um "pare" e contorná-lo, e é uma linha só no código.
  """
  alias Api.Messaging

  # **`async: false` por causa do `com_whatsapp/1`**: ele liga o canal mexendo em
  # `Application.put_env`, que é global ao nó. Rodando em paralelo, a janela em que a flag está
  # ligada é visível para qualquer outro teste async — e foi assim que o
  # `ApiWeb.MessagesControllerTest` passou a falhar de forma intermitente: o paciente dele tem
  # telefone, o WhatsApp aparecia disponível por um instante, e o canal escolhido deixava de ser o
  # e-mail que o teste opta-out. Teste que muda configuração de aplicação não pode ser async.
  use Api.DataCase, async: false

  alias Api.Messaging.Dispatch

  describe "avaliar/2 — as quatro perguntas, na ordem" do
    test "sem consentimento na ficha, não sai nada" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: false, email: "quem@example.com")

      assert {:skip, :sem_consentimento} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
    end

    test "consentimento sem contato nenhum é :sem_contato, não erro" do
      # A ficha **legada**, anterior ao telefone obrigatório (doc 52 §9 / D6b): a ação recusa
      # criar este caso hoje, mas a linha existe no banco e a leitura tem de explicá-la em vez de
      # estourar.
      ctx = clinica()
      paciente = paciente_legado_sem_tel!(ctx, comunicacao: true, email: nil)

      assert {:skip, :sem_contato} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
    end

    test "com e-mail e consentimento, sai por e-mail" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "Maria@Example.COM ")

      assert {:ok, :email, "maria@example.com"} =
               Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
    end

    test "o consentimento é perguntado ANTES do contato" do
      # Importa porque a ordem é o que evita "não tem e-mail" aparecer na tela quando a causa
      # real é falta de autorização — dois motivos diferentes, duas ações diferentes da recepção.
      ctx = clinica()
      paciente = paciente_legado_sem_tel!(ctx, comunicacao: false, email: nil)

      assert {:skip, :sem_consentimento} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
    end
  end

  describe "opt-out (§10)" do
    test "destino que pediu para parar não recebe" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "parou@example.com")
      Messaging.opt_out(:email, "parou@example.com", "link")

      assert {:skip, :opt_out} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
    end

    test "o opt-out GLOBAL (clinic_id nulo) vale para qualquer clínica" do
      # É o caso da v1: número/remetente único da Cinetra (C11), então "SAIR" é global. Se a
      # leitura só enxergasse o opt-out da própria clínica, continuaríamos mandando.
      outra = clinica()
      paciente = paciente_com(outra, comunicacao: true, email: "global@example.com")
      Messaging.opt_out(:email, "global@example.com", "spam")

      assert {:skip, :opt_out} = Dispatch.avaliar(paciente, clinic_id: outra.clinic.id)
    end

    test "opt-out de OUTRA clínica não bloqueia esta" do
      a = clinica()
      b = clinica()
      paciente = paciente_com(b, comunicacao: true, email: "so-na-a@example.com")
      Messaging.opt_out(:email, "so-na-a@example.com", "link", clinic_id: a.clinic.id)

      assert {:ok, :email, _} = Dispatch.avaliar(paciente, clinic_id: b.clinic.id)
    end

    test "revogar devolve o destino ao envio" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "voltou@example.com")
      Messaging.opt_out(:email, "voltou@example.com", "link")
      Messaging.revoke_opt_out(ctx.scope, :email, "voltou@example.com")

      assert {:ok, :email, _} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
    end

    test "registrar duas vezes não duplica" do
      ctx = clinica()
      Messaging.opt_out(:email, "repetido@example.com", "spam")
      Messaging.opt_out(:email, "repetido@example.com", "spam")

      assert [_um] =
               Messaging.list_opt_outs!(:email, "repetido@example.com", ctx.clinic.id,
                 authorize?: false
               )
    end
  end

  describe "normalizar/2" do
    test "e-mail vira minúsculas e sem espaço" do
      assert Dispatch.normalizar(:email, "  Ana@Ex.COM ") == "ana@ex.com"
    end

    test "campo preenchido com qualquer coisa não vira destino" do
      assert Dispatch.normalizar(:email, "não é e-mail") == nil
      assert Dispatch.normalizar(:email, "") == nil
    end

    test "telefone brasileiro vira E.164" do
      assert Dispatch.normalizar(:whatsapp, "(11) 98765-4321") == "+5511987654321"
      assert Dispatch.normalizar(:whatsapp, "11 3456-7890") == "+551134567890"
      assert Dispatch.normalizar(:whatsapp, "+55 11 98765-4321") == "+5511987654321"
    end

    test "número curto demais não vira destino" do
      # Melhor "sem contato" na tela, que alguém corrige, do que tentar entregar em lixo.
      assert Dispatch.normalizar(:whatsapp, "1234") == nil
      assert Dispatch.normalizar(:whatsapp, "") == nil
    end
  end

  describe "ordem de canal (C8) e a reserva que não vira contorno (§10.4)" do
    test "na fase 1 o WhatsApp não tem transporte, então o e-mail atende" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, tel: "11987654321", email: "b@example.com")

      assert {:ok, :email, "b@example.com"} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
    end

    test "com WhatsApp ligado, ele é o padrão" do
      com_whatsapp(fn ->
        ctx = clinica()

        paciente =
          paciente_com(ctx, comunicacao: true, tel: "11987654321", email: "b@example.com")

        assert {:ok, :whatsapp, "+5511987654321"} =
                 Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
      end)
    end

    test "sem telefone, cai para o e-mail" do
      com_whatsapp(fn ->
        ctx = clinica()
        paciente = paciente_legado_sem_tel!(ctx, comunicacao: true, email: "b@example.com")

        assert {:ok, :email, "b@example.com"} =
                 Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
      end)
    end

    test "com FIXO, cai para o e-mail — fixo não recebe WhatsApp" do
      # O par do "telefone obrigatório" (§9): aceitar fixo na ficha só é honesto se o envio
      # souber que ele não serve para WhatsApp. Sem isto, a mensagem sairia para um número que
      # nunca vai entregar e a falha só apareceria no webhook, horas depois.
      com_whatsapp(fn ->
        ctx = clinica()

        paciente =
          paciente_com(ctx, comunicacao: true, tel: "(11) 3456-7890", email: "b@example.com")

        assert {:ok, :email, "b@example.com"} =
                 Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
      end)
    end

    test "OPT-OUT do WhatsApp **não** cai para o e-mail — é o §10.4" do
      # A regra inteira da §10.4 é esta linha. Sem ela o paciente responde SAIR no WhatsApp e a
      # mesma mensagem chega por e-mail dez segundos depois: tecnicamente correto e, do lado de
      # lá, deboche.
      com_whatsapp(fn ->
        ctx = clinica()

        paciente =
          paciente_com(ctx, comunicacao: true, tel: "11987654321", email: "b@example.com")

        Messaging.opt_out(:whatsapp, "+5511987654321", "palavra_chave")

        assert {:skip, :opt_out} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
      end)
    end
  end

  describe "janela de silêncio (§7)" do
    test "fora da janela, sai agora" do
      clinic = %{timezone: "America/Sao_Paulo", msg_silencio_inicio: 21, msg_silencio_fim: 8}
      meio_dia = as_utc(~D[2026-08-10], 12, "America/Sao_Paulo")

      assert Dispatch.quando_enviar(clinic, meio_dia) == nil
    end

    test "dentro da janela noturna, adia para o fim dela (e não descarta)" do
      clinic = %{timezone: "America/Sao_Paulo", msg_silencio_inicio: 21, msg_silencio_fim: 8}
      onze_da_noite = as_utc(~D[2026-08-10], 23, "America/Sao_Paulo")

      quando = Dispatch.quando_enviar(clinic, onze_da_noite)

      assert DateTime.shift_zone!(quando, "America/Sao_Paulo").hour == 8
      assert DateTime.to_date(DateTime.shift_zone!(quando, "America/Sao_Paulo")) == ~D[2026-08-11]
    end

    test "madrugada é o MESMO dia às 8h, não o seguinte" do
      # A janela cruza a meia-noite; escrever `hora >= inicio and hora < fim` faria a comparação
      # ser sempre falsa e a janela silenciar nada.
      clinic = %{timezone: "America/Sao_Paulo", msg_silencio_inicio: 21, msg_silencio_fim: 8}
      duas_da_manha = as_utc(~D[2026-08-11], 2, "America/Sao_Paulo")

      quando = Dispatch.quando_enviar(clinic, duas_da_manha)
      local = DateTime.shift_zone!(quando, "America/Sao_Paulo")

      assert local.hour == 8
      assert DateTime.to_date(local) == ~D[2026-08-11]
    end

    test "sem janela configurada, nunca adia" do
      clinic = %{timezone: "America/Sao_Paulo", msg_silencio_inicio: nil, msg_silencio_fim: nil}

      assert Dispatch.quando_enviar(clinic, DateTime.utc_now()) == nil
    end

    test "janela de largura zero não silencia o dia inteiro" do
      # 21h→21h é configuração sem sentido que a tela pode produzir; o tratamento ingênuo
      # (`hora >= 21 or hora < 21`) seria verdadeiro sempre e nada sairia, nunca.
      clinic = %{timezone: "America/Sao_Paulo", msg_silencio_inicio: 21, msg_silencio_fim: 21}

      assert Dispatch.quando_enviar(clinic, as_utc(~D[2026-08-10], 22, "America/Sao_Paulo")) ==
               nil
    end
  end

  describe "dispatch/5" do
    test "grava a mensagem ancorada na PRESENÇA e enfileira o envio" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, message} =
               Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao,
                 disparado_por_id: ctx.owner.id
               )

      assert message.attendance_id == presenca.id
      assert message.appointment_id == appt.id
      assert message.status == :pendente
      assert message.template == "confirmacao_v1"
      assert message.destino == "ana@example.com"
      assert message.disparado_por_id == ctx.owner.id
      assert message.vars["clinica"] == ctx.clinic.nome
    end

    test "não levanta quando o paciente não pode receber — devolve o motivo" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: false)
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:skip, :sem_consentimento} =
               Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
    end
  end

  # ---- helpers ----

  # `Keyword.put` sobre o que já está lá, e **não** uma lista nova: a config de teste também
  # aponta o `whatsapp_adapter` para o duplo em memória, e substituir a lista inteira devolveria
  # o adapter para a Zernio de verdade — que não tem credencial na suíte, então
  # `Transport.disponivel?/1` responderia `false` e estes testes provariam o contrário do que
  # dizem no nome.
  defp com_whatsapp(fun) do
    anterior = Application.get_env(:api, Api.Messaging.Transport, [])

    Application.put_env(
      :api,
      Api.Messaging.Transport,
      Keyword.put(anterior, :whatsapp_habilitado, true)
    )

    on_exit(fn -> Application.put_env(:api, Api.Messaging.Transport, anterior) end)
    fun.()
  end

  defp as_utc(date, hora, tz) do
    {:ok, local} = DateTime.new(date, Time.new!(hora, 0, 0), tz)
    DateTime.shift_zone!(local, "Etc/UTC")
  end
end
