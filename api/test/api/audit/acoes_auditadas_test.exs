defmodule Api.Audit.AcoesAuditadasTest do
  @moduledoc """
  Os **nomes de ação** que a trilha grava — a outra metade da tripwire de
  `capture_ligado_test.exs`, que amarrava só a lista de RECURSOS.

  ## O buraco que este teste fecha

  `Api.Audit.Capture` grava `changeset.action.name`, e a tela traduz esse nome em duas tabelas
  mantidas à mão (`ACTION_LABELS` e `HEADLINES`, em `web/src/lib/audit.ts`). Não havia nada
  ligando as duas pontas: renomear uma ação aqui — ou criar um recurso com verbos próprios —
  deixava os dois lados verdes, e o estrago aparecia só na tela, em dois lugares ao mesmo tempo:

    * o feed caía na rede genérica. Medido em dev: a fila de espera exibiu sete linhas seguidas
      de "Criou um registro" / "Removeu um registro" — porque a tela traduzia `create`/`destroy`
      e o recurso grava `enqueue`/`dequeue`. Sem tipo, sem nome, e sem diff (o `create` não
      mostra diff e o `destroy` não tem um): a linha existia e não informava nada;
    * o filtro da sidebar oferecia recortes por nomes que **não existem** na coluna `action`, e
      `?acao=pause` devolvia zero linhas. Vazio silencioso lê como "não aconteceu nada" — e a
      auditoria é justamente a tela onde isso não pode acontecer.

  Os nomes saem do DSL do Ash (`Ash.Resource.Info.actions/1` recortado pelo `on:` do próprio
  `Capture`), nunca de uma lista redigitada: é o que faz uma ação NOVA cair aqui sozinha.

  `Api.Records.Attachment` fica de fora pelo mesmo motivo do outro teste — a trilha dele é
  escrita pelo caminho de acesso (`Api.Audit.Acesso`), fora de changeset. As ações desse caminho
  (`visualizou_ficha`, `acesso_negado`, `enviou`/`visualizou`/`renomeou`/`removeu`) não saem do
  DSL, e já estão presas pelo comportamento em `acesso_test.exs` — mas entram na lista espelhada
  na tela do mesmo jeito, porque para quem lê o feed elas são ações como as outras.
  """
  use ExUnit.Case, async: true

  # O combinado com a tela. Espelhado em `web/src/lib/audit.test.ts` (`ACOES_DO_BACKEND`), que
  # afirma que cada par tem verbo curto e frase de feed.
  #
  # A lista é explícita de propósito, como a de recursos: derivá-la do DSL dos dois lados faria
  # o teste concordar com qualquer renomeação — que é exatamente o que se quer pegar.
  @acoes %{
    Api.Scheduling.Appointment => [
      :schedule,
      :add_participant,
      :remove_participant,
      :reschedule,
      :set_pkg_hold,
      :cancel,
      :reopen,
      :apply_participant_rollup,
      :exclude
    ],
    Api.Scheduling.Attendance => [
      :create,
      :transition,
      :mark_present,
      :mark_absent,
      :reopen_attendance,
      :justify_absence,
      :set_pkg_hold,
      :remove
    ],
    Api.Records.Patient => [:create, :update, :deactivate, :reactivate],
    Api.Directory.Professional => [:create, :update, :deactivate, :reactivate],
    Api.Directory.AppointmentType => [:create, :update, :archive, :restore],
    Api.Accounts.Membership => [:invite, :invite_by_email, :update, :accept_invite, :revoke_access],
    Api.Accounts.Clinic => [:onboard, :update_settings, :update_messaging, :update_info],
    Api.Scheduling.ClinicHours => [:set_day],
    Api.Scheduling.ProfessionalHours => [:set_day],
    Api.Scheduling.ScheduleException => [:create, :destroy],
    Api.Packages.Package => [:create, :mark_paused, :mark_active, :mark_cancelled],
    Api.Waitlist.WaitlistEntry => [:enqueue, :update, :dequeue]
  }

  defp captura(resource) do
    resource
    |> Ash.Resource.Info.changes()
    |> Enum.find(&match?(%{change: {Api.Audit.Capture, _}}, &1))
  end

  # As ações do recurso que o `Capture` de fato cobre: os tipos do `on:`, e nada além.
  defp acoes_capturadas(resource) do
    %{on: on} = captura(resource)

    resource
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&(&1.type in on))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  for {resource, esperadas} <- @acoes do
    test "#{inspect(resource)} grava exatamente as ações combinadas com a tela" do
      assert acoes_capturadas(unquote(resource)) == Enum.sort(unquote(esperadas)),
             """
             As ações auditadas de #{inspect(unquote(resource))} mudaram.

             A tela traduz o nome da AÇÃO DO ASH (`changeset.action.name`) — não o da code
             interface nem o verbo de produto. Atualize a outra ponta junto:

               - web/src/lib/audit.ts        → `ACTION_LABELS` e `HEADLINES` do recurso
               - web/src/lib/audit.test.ts   → `ACOES_DO_BACKEND`

             Ação renomeada NÃO substitui a entrada antiga: a trilha guarda o que aconteceu, e
             as linhas já gravadas continuam com o nome velho. Marque-o como aposentado e deixe
             o rótulo (é o caso de `mark_completed` e de `set_package`).
             """
    end
  end

end
