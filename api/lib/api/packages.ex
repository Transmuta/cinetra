defmodule Api.Packages do
  @moduledoc """
  Domínio dos **pacotes** (doc 25, Fatia 3) — recursos por-tenant por atributo (`clinic_id`,
  ADR-017), no molde de `Api.Scheduling`/`Api.Waitlist`.

  Reúne o pacote (`Package`), sua grade (`PackageSchedule`) e o motor puro de série
  (`Api.Packages.Series`, sem recurso — só função).

  Como nos outros domínios por-tenant, os **wrappers deste módulo** centralizam o `in_clinic/2`
  (GUC de tenant para a RLS, ADR-018) na leitura; a escrita seta a GUC dentro da própria ação
  (`SetTenantGuc`).
  """
  use Ash.Domain, otp_app: :api

  import Api.Tenancy, only: [in_clinic: 2]

  resources do
    resource Api.Packages.Package do
      define :create_package, action: :create
      define :list_packages, action: :read
      define :get_package, action: :read, get_by: [:id]
    end

    resource Api.Packages.PackageSchedule do
      define :get_package_schedule, action: :read, get_by: [:id]
    end
  end

  @doc """
  A **prévia** da série de um pacote antes de criá-lo (o save-gate, doc 02 §1.5). Projeta e
  classifica cada ocorrência sem escrever. Delega a `Api.Packages.Preview` — ver lá o contrato.
  """
  defdelegate preview_series(scope, params), to: Api.Packages.Preview, as: :run

  @doc """
  Cria o pacote **e enfileira a materialização** da série (doc 04 §6). O ponto de entrada da
  criação: o controller chama isto, não `create_package` cru.

  Roda a prévia server-side (nunca confia no cliente) e **decide antes de escrever**:

    * ocorrência **fora do expediente** → `{:error, {:fora_expediente, previa}}`. É bloqueio
      absoluto (D14): encaixe não isenta, então nem `forcar` materializa esses — recusar de saída
      evita um pacote que jamais se agenda por inteiro.
    * conflito/turma cheia **sem `forcar`** → `{:error, {:precisa_confirmar, previa}}`. A tela
      reapresenta com o "agendar mesmo assim".
    * caso contrário → cria o pacote, enfileira `Api.Packages.Materializer` (que grava as sessões
      como `encaixe` quando `forcar`), e devolve `{:ok, package}`.

  A criação do pacote e o enfileiramento do job compartilham a transação da ação
  (`Oban.insert` dentro do `after_action`), então não há pacote sem job nem job sem pacote.
  """
  def create_series(%Api.Scope{} = scope, params, opts \\ []) do
    forcar = Keyword.get(opts, :forcar, false)

    with {:ok, previa} <- preview_series(scope, params),
         :ok <- gate(previa, forcar) do
      attrs = Map.merge(params, %{materialize?: true, forcar: forcar})
      create_package(attrs, scope: scope)
    end
  end

  defp gate(%{ocorrencias: ocorrencias} = previa, forcar) do
    cond do
      Enum.any?(ocorrencias, &(&1.issue == :fora_expediente)) ->
        {:error, {:fora_expediente, previa}}

      previa.bloqueios > 0 and not forcar ->
        {:error, {:precisa_confirmar, previa}}

      true ->
        :ok
    end
  end

  @doc """
  Os pacotes de um paciente na clínica ativa, com os derivados carregados. Wrapper de leitura sob
  RLS (ADR-018) — o controller chama isto, não a code interface crua.
  """
  def list_patient_packages(%Api.Scope{} = scope, patient_id, opts \\ []) do
    in_clinic(scope, fn ->
      list_packages!(
        scope: scope,
        query: [filter: [patient_id: patient_id], sort: [inserted_at: :desc]],
        load: Keyword.get(opts, :load, [:usadas, :restantes, :acabando, :schedule])
      )
    end)
  end
end
