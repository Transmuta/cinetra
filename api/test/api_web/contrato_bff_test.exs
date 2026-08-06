defmodule ApiWeb.ContratoBffTest do
  @moduledoc """
  **A2 (doc 101)** — o contrato BFF↔API deixa de ser mantido a olho.

  Este teste monta um mundo pequeno e completo, **atravessa o roteador de verdade** nos cinco
  recursos quentes (agenda, pacientes, pacotes, notificações e fila) e grava em `contratos/bff/`
  o corpo que a API respondeu. Os `.test.ts` do BFF leem esses arquivos no lugar do JSON que hoje
  eles inventam dentro do próprio teste.

  ## O que isso pega, e o que não pega

  Pega o que morde: renomear um campo num serializer, remover um, mudar o tipo de um valor ou a
  forma de um envelope. Hoje nada disso quebra build ou teste — o campo simplesmente chega
  `undefined` na tela, em runtime, calado (`web/src/lib/agenda.ts:17` narra a vez em que
  aconteceu).

  Não pega divergência de **significado** com a mesma forma (`status: "cancelado"` virar
  `"anulado"` continua sendo string), e não substitui os testes de cada lado. É a metade barata do
  problema, de propósito: sem codegen, sem esquema, sem tipo derivado — só **uma fonte do
  exemplo**.

  ## Como ele reprova

  A fixture é regravada a cada `mix test`. Se a serialização mudou, o arquivo muda, `git diff`
  fica sujo e o passo `Contrato BFF↔API` do CI reprova. É o mesmo mecanismo de `mix format
  --check-formatted`: o artefato é gerado, e a checagem é que ele não mudou sem alguém olhar.

  A determinância byte a byte é responsabilidade de `Api.ContratoBff` — leia o moduledoc de lá
  antes de acrescentar uma amostra que carregue relógio.

  ## Por que as escritas passam pelo domínio e as leituras pela HTTP

  Escrever pela fronteira exigiria o relógio de parede (o `Api.Scope` do `LoadScope` sempre resolve
  `now` como agora), e o mundo montado precisa ter **passado e futuro** em volta de um instante
  fixo. Escrevendo pelo domínio, o relógio é injetado (ADR-009) e o mundo fica igual em toda
  rodada. O que se está contratando é a **resposta**, e essa vem inteira pela porta HTTP real —
  roteador, plugs, `LoadScope`, controller, serializer.
  """
  use ApiWeb.ConnCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Accounts
  alias Api.ContratoBff
  alias Api.Directory
  alias Api.Notifications
  alias Api.Packages
  alias Api.Records
  alias Api.Scheduling
  alias Api.Waitlist

  # O e-mail é fixo (e não `email_unico/1`) porque ele pode alcançar a resposta: dado que viaja
  # para a fixture não pode carregar um inteiro de sequência. `contrato-bff@` não é usado por
  # nenhum outro teste da suíte.
  @email "contrato-bff@example.com"

  setup do
    {segunda, deslocamento} = ContratoBff.semana()

    owner = sign_in!(@email)
    {:ok, clinic} = Accounts.onboard_clinic("Clínica do Contrato", %{}, actor: owner)

    tz = clinic.timezone

    # O relógio do DOMÍNIO fica entre o passado e o futuro do mundo montado: uma semana antes da
    # semana-âncora. Assim a sessão de `segunda - 28` já aconteceu (dá para concluí-la) e as da
    # semana-âncora ainda não — para o relógio injetado **e** para o relógio de parede, que é o
    # que a leitura HTTP vai usar.
    agora = ContratoBff.as(Date.add(segunda, -7), "09:00", tz)
    escopo = escopo(owner, clinic, now: agora)

    prof =
      Directory.create_professional!("Dra. Ana Ribeiro", %{tel: "+5511987650001"},
        tenant: clinic.id,
        actor: owner
      )

    tipo =
      Directory.create_appointment_type!(
        %{nome: "Pilates Solo", duracao_minutos: 50, cor: "#0FB5A6", icon: "Activity"},
        tenant: clinic.id,
        actor: owner
      )

    paciente =
      Records.create_patient!(
        "Maria Souza",
        %{tel: "+5511987650002", email: "maria@example.com", cpf: "11144477735"},
        tenant: clinic.id,
        actor: owner
      )

    %{
      owner: owner,
      clinic: clinic,
      tz: tz,
      escopo: escopo,
      prof: prof,
      tipo: tipo,
      paciente: paciente,
      segunda: segunda,
      deslocamento: deslocamento
    }
  end

  test "agenda", ctx do
    appt = agendar(ctx, ctx.segunda, "10:00")

    janela =
      resposta(
        ctx,
        "/api/appointments?from=#{Date.to_iso8601(ctx.segunda)}&to=#{Date.to_iso8601(Date.add(ctx.segunda, 4))}"
      )

    bloco = resposta(ctx, "/api/appointments/#{appt.id}")

    gravar(ctx, "agenda", %{
      "janela" => %{
        rota: "GET /api/appointments?from=&to=&professional_id=",
        consumido_por: "web/src/lib/server/appointments.ts — fetchAgenda",
        corpo: janela
      },
      "bloco" => %{
        rota: "GET /api/appointments/:id",
        consumido_por: "web/src/lib/server/appointments.ts — fetchAppointment",
        corpo: bloco
      }
    })
  end

  test "pacientes", ctx do
    passada = agendar(ctx, Date.add(ctx.segunda, -28), "09:00")
    concluir(ctx, passada)
    agendar(ctx, Date.add(ctx.segunda, 1), "11:00")

    gravar(ctx, "pacientes", %{
      "lista" => %{
        rota: "GET /api/patients?q=&filter=&limit=&offset=",
        consumido_por: "web/src/lib/server/patients.ts — fetchPatients",
        corpo: resposta(ctx, "/api/patients")
      },
      "ficha" => %{
        rota: "GET /api/patients/:id",
        consumido_por: "web/src/lib/server/patients.ts — fetchPatient",
        corpo: resposta(ctx, "/api/patients/#{ctx.paciente.id}")
      },
      "historico" => %{
        rota: "GET /api/patients/:id/history?limit=&offset=",
        consumido_por: "web/src/lib/server/patients.ts — fetchPatientHistory",
        corpo: resposta(ctx, "/api/patients/#{ctx.paciente.id}/history")
      }
    })
  end

  test "pacotes", ctx do
    pacote = pacote!(ctx)

    gravar(ctx, "pacotes", %{
      "lista_do_paciente" => %{
        rota: "GET /api/patients/:patient_id/packages",
        consumido_por: "web/src/lib/server/packages.ts — fetchPatientPackages",
        corpo: resposta(ctx, "/api/patients/#{ctx.paciente.id}/packages")
      },
      "trilha" => %{
        rota: "GET /api/packages/:id/sessions",
        consumido_por: "web/src/lib/server/packages.ts — fetchPackageSessions",
        corpo: resposta(ctx, "/api/packages/#{pacote.id}/sessions")
      },
      "previa" => %{
        rota: "POST /api/packages/preview",
        consumido_por: "web/src/lib/server/packages.ts — previewSeries",
        corpo: previa(ctx)
      }
    })
  end

  test "notificacoes", ctx do
    notificar(ctx, %{
      kind: :appointment_scheduled,
      title: "Novo agendamento",
      body: "Maria Souza — segunda, 10:00",
      data: %{"day" => Date.to_iso8601(ctx.segunda)}
    })

    notificar(ctx, %{
      kind: :member_joined,
      title: "Novo membro na clínica",
      body: "Dra. Ana Ribeiro entrou como profissional",
      data: %{}
    })

    gravar(ctx, "notificacoes", %{
      "caixa" => %{
        rota: "GET /api/notifications?unread=&limit=&offset=",
        consumido_por: "web/src/lib/server/notifications.ts — fetchNotifications",
        corpo: resposta(ctx, "/api/notifications")
      },
      "badge" => %{
        rota: "GET /api/notifications/unread-count",
        consumido_por: "web/src/lib/server/notifications.ts — fetchUnreadCount",
        corpo: resposta(ctx, "/api/notifications/unread-count")
      }
    })
  end

  test "fila", ctx do
    {:ok, _entry} =
      Waitlist.enqueue_entry(ctx.escopo, %{
        patient_id: ctx.paciente.id,
        prio: :urgente,
        janela: :manha,
        obs: "Prefere início da semana",
        professional_ids: [ctx.prof.id],
        rules: [%{tipo: :semana, dows: [1, 3], periodos: [["08:00", "12:00"]]}]
      })

    gravar(ctx, "fila", %{
      "lista" => %{
        rota: "GET /api/waitlist?limit=&offset=&prio=",
        consumido_por: "web/src/lib/server/waitlist.ts — fetchWaitlist",
        corpo: resposta(ctx, "/api/waitlist")
      }
    })
  end

  # A **vaga** (`GET /api/waitlist/slots`) fica de fora, e é decisão: o `SlotFinder` varre a partir
  # de AGORA, então as datas que ele devolve mudam com o dia em que a suíte roda — a fixture
  # ficaria suja todo dia e o gate viraria ruído em uma semana. O `.test.ts` daquele caminho segue
  # com corpo escrito à mão, e a nota está no doc.

  # ---- o mundo ----

  defp agendar(ctx, data, hhmm) do
    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: ContratoBff.as(data, hhmm, ctx.tz),
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id]
        },
        scope: ctx.escopo
      )

    appt
  end

  defp concluir(ctx, appt) do
    {:ok, _} =
      Scheduling.transition_participant(ctx.escopo, appt.id, ctx.paciente.id, :complete)

    :ok
  end

  defp pacote!(ctx) do
    {:ok, pacote} =
      Packages.create_series(ctx.escopo, %{
        nome: "Pilates 4 sessões",
        total: 4,
        falta_punitiva: true,
        cor: "#0FB5A6",
        data_inicio: ctx.segunda,
        patient_id: ctx.paciente.id,
        appointment_type_id: ctx.tipo.id,
        grade: %{
          dows: [1, 3],
          horarios: %{"1" => "10:00", "3" => "10:00"},
          professional_id: ctx.prof.id
        }
      })

    # A materialização das sessões é job de fundo; sem drenar a fila, a trilha sai vazia e a
    # fixture descreveria um pacote que não existe.
    Oban.drain_queue(queue: :housekeeping)

    pacote
  end

  defp previa(ctx) do
    corpo = %{
      "nome" => "Pilates 4 sessões",
      "total" => 4,
      "falta_punitiva" => true,
      "cor" => "#0FB5A6",
      "data_inicio" => Date.to_iso8601(ctx.segunda),
      "patient_id" => ctx.paciente.id,
      "appointment_type_id" => ctx.tipo.id,
      "grade" => %{
        "dows" => [1, 3],
        "horarios" => %{"1" => "14:00", "3" => "14:00"},
        "professional_id" => ctx.prof.id
      }
    }

    ctx.owner |> as() |> post("/api/packages/preview", corpo) |> json_response(200)
  end

  defp notificar(ctx, attrs) do
    {:ok, n} =
      Notifications.create_notification(
        Map.merge(%{recipient_id: ctx.owner.id}, attrs),
        tenant: ctx.clinic.id,
        authorize?: false
      )

    n
  end

  # ---- a leitura, pela porta de verdade ----

  defp resposta(ctx, rota) do
    ctx.owner |> as() |> get(rota) |> json_response(200)
  end

  defp gravar(ctx, recurso, amostras) do
    caminho = ContratoBff.gravar(recurso, ctx.deslocamento, amostras)

    assert File.exists?(caminho),
           "a fixture de `#{recurso}` não foi gravada em #{caminho} — sem ela os testes do BFF " <>
             "voltam a validar o BFF contra o BFF"
  end
end
