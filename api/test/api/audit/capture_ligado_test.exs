defmodule Api.Audit.CaptureLigadoTest do
  @moduledoc """
  Onde a trilha está ligada, e **com que `on:`** (bate-volta, causa C8).

  Dois buracos que o bate-volta mediu:

    * o `:destroy` só tinha rede no `Membership`. Tirá-lo do `on:` de outros **nove** recursos
      deixava 156 testes verdes — e o argumento contra isso está escrito no próprio código
      (`membership.ex`): sem a trilha o registro some **inteiro**, e não sobra nem o estado final
      do qual inferir o que houve. Vale igual para `schedule_exception` ("Removeu exceção") e
      `waitlist_entry` ("Tirou {p} da fila"), que têm destroy como ação normal;
    * nada garantia que um recurso **continuasse** com o `Capture`. Removê-lo inteiro de um
      recurso é uma linha, e o efeito — parar de auditar — é invisível a qualquer teste de
      comportamento dos outros.

  Este teste lê a verdade do **DSL do Ash**, não de uma lista redigitada: é a mesma técnica do
  `on_delete_test.exs`, e por isso um recurso novo com `Capture` entra aqui sozinho.

  O `Attachment` fica de fora por decisão registrada no próprio recurso: a trilha dele é escrita
  pelo caminho de ACESSO (`Api.Audit.Acesso`), porque a `:visualizou` não passa por changeset e
  a remoção precisa do nome já carregado. Ligar os dois gravava tudo em duplicata.
  """
  use ExUnit.Case, async: true

  # Os recursos que DEVEM ter a captura. Lista explícita de propósito: se ela fosse derivada de
  # "quem tem o change", o teste concordaria com qualquer remoção — que é exatamente o que se
  # quer pegar.
  @auditados [
    Api.Scheduling.Appointment,
    Api.Scheduling.Attendance,
    Api.Scheduling.ClinicHours,
    Api.Scheduling.ProfessionalHours,
    Api.Scheduling.ScheduleException,
    Api.Records.Patient,
    Api.Directory.Professional,
    Api.Directory.AppointmentType,
    Api.Accounts.Membership,
    Api.Accounts.Clinic,
    Api.Packages.Package,
    Api.Waitlist.WaitlistEntry
  ]

  defp captura(resource) do
    resource
    |> Ash.Resource.Info.changes()
    |> Enum.find(&match?(%{change: {Api.Audit.Capture, _}}, &1))
  end

  for resource <- @auditados do
    test "#{inspect(resource)} tem a captura da trilha" do
      assert captura(unquote(resource)),
             "#{inspect(unquote(resource))} deixou de gravar na trilha"
    end

    # O default do Ash em `changes do` é `[:create, :update]` — ele **omite `:destroy`**. Sem o
    # `on:` explícito, apagar um registro não deixa rastro nenhum, e nada fica vermelho.
    test "#{inspect(resource)} captura também o :destroy" do
      %{on: on} = captura(unquote(resource))

      assert :destroy in on,
             "o `on:` do Capture em #{inspect(unquote(resource))} não cobre :destroy — " <>
               "o default do Ash é [:create, :update] e apagar passaria em silêncio"
    end
  end

  # A TRIPWIRE entre as duas pontas. `ResourceKind` é a autoridade (a API devolve 422 para valor
  # fora dela), e a tela repete a lista em `web/src/lib/audit.ts` — em CINCO tabelas: a união
  # `AuditResource`, `RESOURCE_GROUPS`, `RESOURCE_LABELS`, `ACTION_LABELS` e `HEADLINES`.
  #
  # Não há compilador que ligue os dois lados: são linguagens diferentes, e o container da API
  # não enxerga `web/`. É a mesma situação da paleta de `AppointmentType`, e a mesma saída —
  # mudar a lista aqui deixa um teste vermelho **pedindo por escrito** que a outra ponta mude
  # junto. Sem isto, o bate-volta mediu: acrescentar um valor ao enum deixava os dois lados
  # verdes, e o recurso novo simplesmente não aparecia na tela.
  test "o enum é o combinado — mudou aqui, mude web/src/lib/audit.ts junto" do
    assert Enum.sort(Api.Audit.ResourceKind.values()) ==
             Enum.sort([
               :appointment,
               :attendance,
               :patient,
               :professional,
               :membership,
               :clinic,
               :appointment_type,
               :clinic_hours,
               :professional_hours,
               :schedule_exception,
               :package,
               :waitlist_entry,
               :attachment,
               :seguranca
             ]),
           """
           A lista de recursos da trilha mudou. Atualize a outra ponta em web/src/lib/audit.ts:
             - a união `AuditResource`
             - `RESOURCE_GROUPS`  (senão o recurso não tem faceta na sidebar)
             - `RESOURCE_LABELS`  (o tipo Record<> já obriga)
             - `ACTION_LABELS` e `HEADLINES` (senão a tela mostra o átomo cru)
           """
  end

  test "todo recurso com Capture declara um resource do enum da trilha" do
    validos = Api.Audit.ResourceKind.values()

    for resource <- @auditados do
      %{change: {Api.Audit.Capture, opts}} = captura(resource)
      kind = Keyword.fetch!(opts, :resource)

      assert kind in validos,
             "#{inspect(resource)} grava como #{inspect(kind)}, que não está em ResourceKind"
    end
  end
end
