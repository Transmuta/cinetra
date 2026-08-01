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
  use Oban.Testing, repo: Api.Repo

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

    test "só telefone, com o canal desligado, é :canal_indisponivel — NÃO :sem_contato" do
      # O caso do balcão: a ficha **tem** celular, o que falta é transporte de pé. Enquanto os
      # dois motivos eram o mesmo átomo, a timeline dizia "sem e-mail nem telefone cadastrado"
      # para um paciente com telefone na ficha — mandava a recepção corrigir o que já está certo,
      # e escondia a única causa real (o WhatsApp desligado nesta instalação).
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, tel: "11987654321", email: nil)

      assert {:skip, :canal_indisponivel} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
    end

    test "ficha vazia continua :sem_contato mesmo com o WhatsApp ligado" do
      # O par do teste acima: com transporte de pé, o silêncio volta a ser culpa da ficha — e é
      # aí que "abra a ficha e preencha" é a instrução certa.
      com_whatsapp(fn ->
        ctx = clinica()
        paciente = paciente_legado_sem_tel!(ctx, comunicacao: true, email: nil)

        assert {:skip, :sem_contato} = Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
      end)
    end

    test "só telefone, com o canal ligado, sai por WhatsApp" do
      com_whatsapp(fn ->
        ctx = clinica()
        paciente = paciente_com(ctx, comunicacao: true, tel: "11987654321", email: nil)

        assert {:ok, :whatsapp, "+5511987654321"} =
                 Dispatch.avaliar(paciente, clinic_id: ctx.clinic.id)
      end)
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

    test "dentro do silêncio, a linha guarda PARA QUANDO foi adiada" do
      # A coluna existe para a tela: sem ela a timeline mostra "Na fila" e um instante no passado,
      # e quem lê conclui que falhou — foi o que aconteceu no teste ao vivo de 2026-07-28. O
      # `scheduled_at` do Oban sabia a resposta, mas ele é podado em 7 dias e não é fonte da UI.
      ctx = clinica()
      clinic = com_janela(ctx.clinic, :agora_dentro)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, message} = Dispatch.dispatch(clinic, presenca, paciente, :confirmacao)

      assert message.agendado_para != nil
      # A linha e o job não podem discordar: é o mesmo instante, lido do relógio uma vez só.
      assert_enqueued(worker: Api.Messaging.SendJob, scheduled_at: message.agendado_para)
    end

    test "fora do silêncio, não há nada a prometer" do
      ctx = clinica()
      clinic = com_janela(ctx.clinic, :agora_fora)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, message} = Dispatch.dispatch(clinic, presenca, paciente, :confirmacao)

      # Nulo é "sai agora", e é o que faz a tela não inventar uma previsão para o caso normal.
      assert message.agendado_para == nil
    end

    test "o LEMBRETE não é adiado — dentro do silêncio ele sai assim mesmo" do
      # A exceção de 2026-07-31 (doc 98), e a razão dela é aritmética. Adiar serve a uma mensagem
      # que continua verdadeira horas depois; o lembrete de 2 h não é: gerado às 5h30 para uma
      # sessão das 7h30, ele sairia às 8h — meia hora DEPOIS da sessão que anuncia, dizendo que ela
      # ainda vai acontecer. O silêncio continua valendo para os outros tipos, e o teste acima é
      # quem prova isso.
      ctx = clinica()
      clinic = com_janela(ctx.clinic, :agora_dentro)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, message} = Dispatch.dispatch(clinic, presenca, paciente, :lembrete)

      assert message.agendado_para == nil
      assert_enqueued(worker: Api.Messaging.SendJob)
    end

    test "não enfileira a segunda enquanto a primeira espera" do
      # A trava contra duplicata. Sem ela, o segundo clique dentro da janela de silêncio empilha
      # outra mensagem para o mesmo paciente — e ele recebe as duas de manhã. Medido no dev de
      # 2026-07-28: quatro linhas idênticas, porque quem clica não vê nada acontecer.
      ctx = clinica()
      clinic = com_janela(ctx.clinic, :agora_dentro)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, _} = Dispatch.dispatch(clinic, presenca, paciente, :confirmacao)
      assert {:skip, :ja_na_fila} = Dispatch.dispatch(clinic, presenca, paciente, :confirmacao)
    end

    test "a trava é por TIPO — lembrete na fila não impede a confirmação" do
      # São mensagens diferentes para a mesma sessão; barrar uma pela outra seria calar comunicação
      # que o paciente precisa receber.
      ctx = clinica()
      clinic = com_janela(ctx.clinic, :agora_dentro)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, _} = Dispatch.dispatch(clinic, presenca, paciente, :lembrete)
      assert {:ok, _} = Dispatch.dispatch(clinic, presenca, paciente, :confirmacao)
    end

    test "a trava é por PRESENÇA — a turma não trava por causa de um participante" do
      # A mesma lição que a A2 cobrou com a falta: numa turma, o que vale para um não vale para os
      # outros três. Travar por bloco deixaria os demais sem confirmação nenhuma.
      ctx = clinica()
      clinic = com_janela(ctx.clinic, :agora_dentro)
      turma = Api.Generators.tipo!(ctx, grupo: true, capacidade: 4)
      ana = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      joao = paciente_com(ctx, comunicacao: true, email: "joao@example.com")

      # Duas chamadas no MESMO horário e tipo de grupo caem no mesmo bloco — é como a turma se
      # forma no resto da suíte.
      quando = proximo_dia_util_as(ctx, 10)
      appt = agendamento!(ctx, paciente: ana, tipo: turma, quando: quando)
      _ = agendamento!(ctx, paciente: joao, tipo: turma, quando: quando)

      presencas = presencas_do(ctx, appt)
      de_ana = Enum.find(presencas, &(&1.patient_id == ana.id))
      de_joao = Enum.find(presencas, &(&1.patient_id == joao.id))

      assert {:ok, _} = Dispatch.dispatch(clinic, de_ana, ana, :confirmacao)
      assert {:skip, :ja_na_fila} = Dispatch.dispatch(clinic, de_ana, ana, :confirmacao)
      assert {:ok, _} = Dispatch.dispatch(clinic, de_joao, joao, :confirmacao)
    end

    test "quem já confirmou presença não recebe outra confirmação" do
      # Ele já respondeu que vem: mandar de novo é pedir a mesma coisa duas vezes a quem já
      # respondeu, e no WhatsApp é spam pago.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, message} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
      responder!(ctx, message, :confirmou)

      assert {:skip, :ja_confirmou} =
               Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
    end

    test "confirmar pelo LEMBRETE também conta — o link viaja nos dois" do
      # `SendJob.render/1` põe o link de resposta em toda mensagem, então o paciente pode confirmar
      # respondendo ao lembrete. Se a trava olhasse só as mensagens de confirmação, quem confirmou
      # pelo lembrete continuaria recebendo pedidos de confirmação.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, lembrete} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :lembrete)
      responder!(ctx, lembrete, :confirmou)

      assert {:skip, :ja_confirmou} =
               Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
    end

    test "quem pediu para remarcar NÃO é barrado — a recepção resolve e reconfirma" do
      # `quer_remarcar` é o oposto de "está resolvido": a recepção liga, acerta o horário e a
      # confirmação nova é justamente o que fecha o assunto. Barrar aqui deixaria o pedido sem
      # resposta possível pelo canal que o originou.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, message} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
      entregar!(ctx, message)
      responder!(ctx, message, :quer_remarcar)

      assert {:ok, _} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
    end

    test "duas confirmações é o teto — a terceira não sai" do
      # O teto contra spam. A primeira é a automática da criação (ou o primeiro clique), a segunda é
      # a insistência legítima da recepção; a terceira é o paciente sendo cobrado três vezes pela
      # mesma sessão.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      assert {:ok, primeira} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
      entregar!(ctx, primeira)

      assert {:ok, segunda} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
      entregar!(ctx, segunda)

      assert {:skip, :limite_de_envios} =
               Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
    end

    test "o que FALHOU não gasta o teto — a recepção conserta a ficha e tenta de novo" do
      # Mensagem que falhou não chegou a ninguém, então não é spam. Contá-la travaria exatamente
      # quem mais precisa reenviar: quem corrigiu o e-mail errado na ficha.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      for _ <- 1..2 do
        assert {:ok, message} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
        falhar!(ctx, message)
      end

      assert {:ok, _} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
    end

    test "o teto é por PRESENÇA — a turma não trava por causa de um participante" do
      ctx = clinica()
      turma = Api.Generators.tipo!(ctx, grupo: true, capacidade: 4)
      ana = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      joao = paciente_com(ctx, comunicacao: true, email: "joao@example.com")

      quando = proximo_dia_util_as(ctx, 10)
      appt = agendamento!(ctx, paciente: ana, tipo: turma, quando: quando)
      _ = agendamento!(ctx, paciente: joao, tipo: turma, quando: quando)

      presencas = presencas_do(ctx, appt)
      de_ana = Enum.find(presencas, &(&1.patient_id == ana.id))
      de_joao = Enum.find(presencas, &(&1.patient_id == joao.id))

      for _ <- 1..2 do
        assert {:ok, message} = Dispatch.dispatch(ctx.clinic, de_ana, ana, :confirmacao)
        entregar!(ctx, message)
      end

      assert {:skip, :limite_de_envios} = Dispatch.dispatch(ctx.clinic, de_ana, ana, :confirmacao)
      assert {:ok, _} = Dispatch.dispatch(ctx.clinic, de_joao, joao, :confirmacao)
    end

    test "o teto não alcança lembrete, remarcação nem cancelamento" do
      # Cada um desses anuncia um fato próprio: o lembrete é do cron (N horas antes), e remarcação e
      # cancelamento trazem informação que a confirmação não tinha. Um teto de confirmação que
      # calasse os três seria um controle fazendo quatro coisas com um nome só.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      for _ <- 1..2 do
        assert {:ok, message} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)
        entregar!(ctx, message)
      end

      assert {:ok, _} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :lembrete)
      assert {:ok, _} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :remarcacao)
      assert {:ok, _} = Dispatch.dispatch(ctx.clinic, presenca, paciente, :cancelamento)
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

  # ---- os três estados que as travas de confirmação leem ----
  #
  # Sempre pelas ações do domínio, sob a GUC: escrever o status à mão com `Ash.Seed` deixaria o
  # teste verde com a máquina de entrega quebrada, e é justamente a máquina que o teto consulta.

  # "A mensagem chegou ao paciente" — o que gasta uma unidade do teto.
  defp entregar!(ctx, message) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Messaging.do_mark_sent!(message, %{provider: "resend", provider_message_id: unico_id()},
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end

  # "Não chegou a ninguém" — não gasta o teto (ver o teste do e-mail errado na ficha).
  defp falhar!(ctx, message) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Messaging.do_advance_message!(
        message,
        %{novo_status: :falhou, erro: "mailbox does not exist"},
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end

  # O clique do paciente no link (doc 52 §5), pela mesma ação do controller público.
  defp responder!(ctx, message, resposta) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Messaging.do_record_reply!(message, %{resposta: resposta},
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end

  defp unico_id, do: "prov-#{System.unique_integer([:positive])}"

  # As presenças do bloco, relidas: quem chamou `agendamento!` primeiro tem só a própria carregada,
  # e a turma se forma na segunda chamada.
  defp presencas_do(ctx, appt) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Ash.load!(appt, [:attendances], authorize?: false, tenant: ctx.clinic.id).attendances
    end)
  end

  # A janela de silêncio **relativa ao relógio de agora**, e não horas fixas: `dispatch/5` lê o
  # relógio por dentro (não há injeção ali), então uma janela escrita à mão faria o teste passar
  # de manhã e falhar de madrugada. Ancorando na hora local corrente, as duas asserções valem a
  # qualquer hora do dia. Não toca no banco — o `Dispatch` só lê estes campos da struct.
  defp com_janela(clinic, :agora_dentro), do: janela(clinic, 0, 2)
  defp com_janela(clinic, :agora_fora), do: janela(clinic, 2, 4)

  defp janela(clinic, de, ate) do
    hora = DateTime.utc_now() |> DateTime.shift_zone!(clinic.timezone) |> Map.fetch!(:hour)

    %{clinic | msg_silencio_inicio: rem(hora + de, 24), msg_silencio_fim: rem(hora + ate, 24)}
  end

  defp as_utc(date, hora, tz) do
    {:ok, local} = DateTime.new(date, Time.new!(hora, 0, 0), tz)
    DateTime.shift_zone!(local, "Etc/UTC")
  end
end
