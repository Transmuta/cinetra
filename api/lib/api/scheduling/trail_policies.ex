defmodule Api.Scheduling.TrailPolicies do
  @moduledoc """
  As policies dos recursos `*.Version` gerados pelo AshPaperTrail (doc 25 §11.2, item 3).

  O recurso de versão é um recurso Ash **normal**, e nasce sem `Ash.Policy.Authorizer` — o que
  torna `authorize?: true` um no-op sobre ele. Era a porta dos fundos da A7: um `profissional`
  que não enxerga a agenda do colega lia a trilha inteira da clínica, com `starts_at`,
  `professional_id`, `created_by_id` e as mudanças de `obs` (que *pode* conter dado clínico,
  A-D7) de todo mundo.

  Duas regras, e nenhuma delas cabia num remendo por recurso:

    * **ler é owner·admin** — é o pedido ("tela de auditoria pro admin", §11.4). Recepção e
      profissional não leem histórico de ninguém;
    * **escrever, ninguém** — a trilha é gravada pelo próprio AshPaperTrail e por mais nada.
      Uma trilha que a aplicação pode editar não é trilha.

  ## Por que proibir a escrita não quebra a gravação

  O `CreateNewVersion` grava a versão com `authorize?: Ash.Domain.Info.authorize(domain) ==
  :always`. `Api.Scheduling` usa o default (`:by_default`), então a gravação roda com
  `authorize?: false` e **não passa por policy nenhuma** — a proibição vale só para quem chega
  de fora. Se um dia o domínio virar `authorize :always`, este `forbid_if always()` derruba a
  gravação e o teste da trilha acusa; é o alarme certo, e não um silêncio.

  ## Como isto chega ao recurso gerado

  Pelo par `version_extensions` (que injeta o authorizer no `use Ash.Resource` do recurso de
  versão) + `mixin` (que injeta este bloco no corpo dele) — as duas opções são do DSL do
  AshPaperTrail, sem gambiarra:

      paper_trail do
        version_extensions authorizers: [Ash.Policy.Authorizer]
        mixin Api.Scheduling.TrailPolicies
      end
  """

  defmacro __using__(_opts) do
    quote do
      policies do
        policy action_type(:read) do
          authorize_if {Api.Accounts.Checks.HasClinicRole,
                        roles: [:owner, :admin], clinic_from: :tenant}
        end

        policy action_type([:create, :update, :destroy]) do
          forbid_if always()
        end
      end
    end
  end
end
