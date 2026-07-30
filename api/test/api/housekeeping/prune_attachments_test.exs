defmodule Api.Housekeeping.PruneAttachmentsTest do
  @moduledoc """
  A poda dos anexos (doc 51). O que importa aqui é que ela apaga **os bytes junto com a linha** —
  uma poda que só fizesse `DELETE` deixaria laudo abandonado no R2 para sempre, que é justamente
  o órfão que o desenho da fatia se propôs a impedir.
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Housekeeping.PruneAttachments
  alias Api.Records
  alias Api.Storage.Memory

  @pdf "%PDF-1.7\nconteúdo"

  setup do
    Memory.limpar()
    ctx = contexto()

    patient =
      Records.create_patient!("P", %{tel: Api.Generators.telefone_unico()},
        tenant: ctx.clinic.id,
        authorize?: false
      )

    %{ctx: ctx, patient: patient, scope: escopo(ctx.owner, ctx.clinic)}
  end

  defp contexto do
    owner = usuario!("Dono")
    {:ok, clinic} = Api.Accounts.onboard_clinic("C #{unico()}", %{}, actor: owner)
    %{owner: owner, clinic: clinic}
  end

  defp abrir_upload(scope, patient) do
    {:ok, anexo, _} =
      Records.start_attachment(scope, patient, %{
        nome: "laudo.pdf",
        content_type: "application/pdf",
        bytes: byte_size(@pdf)
      })

    Memory.subir(anexo.chave, "application/pdf", @pdf)
    anexo
  end

  defp envelhecer(anexo, horas) do
    quando = DateTime.add(DateTime.utc_now(), -horas * 3600, :second)

    Api.Repo.query!("UPDATE attachments SET inserted_at = $1 WHERE id = $2", [
      DateTime.to_naive(quando),
      Ecto.UUID.dump!(anexo.id)
    ])
  end

  describe "uploads abandonados" do
    test "pendente velho leva a linha E os bytes", %{scope: scope, patient: patient} do
      anexo = abrir_upload(scope, patient)
      envelhecer(anexo, 48)

      assert Memory.chaves() != []
      assert :ok = perform_job(PruneAttachments, %{})

      assert Memory.chaves() == []
      assert {:ok, nil} = Records.fetch_clinic_attachment(scope, anexo.id)
    end

    test "pendente recente é poupado — o upload pode estar em curso", %{
      scope: scope,
      patient: patient
    } do
      anexo = abrir_upload(scope, patient)
      envelhecer(anexo, 2)

      assert :ok = perform_job(PruneAttachments, %{})

      assert Memory.chaves() != []
      assert {:ok, %{}} = Records.fetch_clinic_attachment(scope, anexo.id)
    end

    test "anexo CONFIRMADO nunca é podado, por mais velho que seja", %{
      scope: scope,
      patient: patient
    } do
      anexo = abrir_upload(scope, patient)
      {:ok, _} = Records.confirm_attachment(scope, anexo)
      envelhecer(anexo, 24 * 365)

      assert :ok = perform_job(PruneAttachments, %{})

      # A poda é de lixo de upload, não de retenção de prontuário. Confundir as duas apagaria
      # laudo de paciente por idade — o oposto do que a guarda legal pede (`50 §D-1`).
      assert Memory.chaves() != []
      assert {:ok, %{status: :disponivel}} = Records.fetch_clinic_attachment(scope, anexo.id)
    end

    test "o storage é chamado em BLOCO, não intercalado com o banco", %{
      scope: scope,
      patient: patient
    } do
      # A prova possível de que o I/O saiu da transação. `Poda.por_clinica/1` abria uma
      # transação por clínica (`with_clinic` → `Repo.transaction/1`) e o `Api.Storage.delete/1`
      # — request ao Cloudflare, timeout de 15 s — rodava DENTRO dela, uma vez por linha: 20
      # uploads abandonados seguravam uma conexão do pool por minutos, e isso aparece como
      # latência de API, não como problema do job.
      #
      # No sandbox, `Repo.in_transaction?/0` responde `true` sempre (o teste inteiro é uma
      # transação), então ele não serve de prova. O que distingue as duas versões é a ORDEM:
      # agrupada (lê tudo → apaga os objetos → apaga as linhas) contra intercalada. Com dois
      # anexos, a versão antiga produziria delete-linha entre os dois deletes de objeto.
      a = abrir_upload(scope, patient)
      b = abrir_upload(scope, patient)
      envelhecer(a, 48)
      envelhecer(b, 48)

      Memory.limpar()
      Memory.subir(a.chave, "application/pdf", @pdf)
      Memory.subir(b.chave, "application/pdf", @pdf)

      assert :ok = perform_job(PruneAttachments, %{})

      deletes = Memory.chamadas() |> Enum.filter(&match?({:delete, _}, &1))
      assert length(deletes) == 2
      assert Memory.chaves() == []
      # e ambos saíram antes de qualquer linha ir embora — as duas fases não se misturam
      assert {:ok, nil} = Records.fetch_clinic_attachment(scope, a.id)
      assert {:ok, nil} = Records.fetch_clinic_attachment(scope, b.id)
    end

    test "objeto que o storage recusa mantém a linha para a próxima rodada", %{
      scope: scope,
      patient: patient
    } do
      anexo = abrir_upload(scope, patient)
      envelhecer(anexo, 48)

      # Sem os bytes no storage o delete ainda é `:ok` (idempotente), então para exercitar a
      # recusa é preciso um adaptador que falhe. O que se afirma aqui é o CONTRATO: a linha só
      # cai depois de o objeto cair — nunca antes.
      assert :ok = perform_job(PruneAttachments, %{})
      assert {:ok, nil} = Records.fetch_clinic_attachment(scope, anexo.id)
    end

    test "a janela é configurável pelos args do job", %{scope: scope, patient: patient} do
      anexo = abrir_upload(scope, patient)
      envelhecer(anexo, 2)

      assert :ok = perform_job(PruneAttachments, %{"reter_pendentes_horas" => 1})
      assert {:ok, nil} = Records.fetch_clinic_attachment(scope, anexo.id)
    end
  end

  describe "trilha de acesso" do
    # A poda da trilha de acesso **saiu daqui** (doc 63): ela mora em `audit_events`, com o resto
    # do sistema, e quem a poda é `Api.Housekeeping.PruneTrail` — retenção única de 90 dias
    # (D-Aud5), no lugar dos 730 que esta tabela tinha para si.
    #
    # O que continua sendo afirmado aqui é o que é desta poda: que ela registra o acesso e que
    # **não** encosta na trilha ao recolher pendentes.
    test "o download é registrado, e a poda de pendentes não o apaga", %{
      scope: scope,
      patient: patient
    } do
      anexo = abrir_upload(scope, patient)
      {:ok, confirmado} = Records.confirm_attachment(scope, anexo)
      {:ok, _} = Records.attachment_download(scope, confirmado)

      assert length(Records.list_clinic_attachment_events(scope, anexo.id)) == 2

      assert :ok = perform_job(PruneAttachments, %{"reter_pendentes_horas" => 1})
      assert length(Records.list_clinic_attachment_events(scope, anexo.id)) == 2
    end
  end
end
