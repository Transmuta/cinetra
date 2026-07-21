defmodule Api.Scheduling.TrailMixin do
  @moduledoc """
  O que o corpo dos recursos `*.Version` gerados pelo AshPaperTrail precisa ganhar por fora
  (doc 25 §11): as **policies** da trilha (§11.2, item 3) e a ação de leitura **paginada** que
  a tela `/configuracoes/auditoria` consome (§11.4).

  Chega ao recurso gerado pelo par `version_extensions` (injeta o authorizer no
  `use Ash.Resource`) + `mixin` (injeta ESTE bloco no fim do corpo do recurso). O mixin é
  `use`d **depois** do `actions do defaults([:read, ...]) end` que o transformer gera, então o
  `read :audit_log` abaixo apenas **soma** — o `:read` cru continua existindo (é o que
  `list_appointment_versions`/`list_attendance_versions` usam).

  ## As policies (§11.2, item 3)

  O recurso de versão é um recurso Ash **normal**, e nasce sem `Ash.Policy.Authorizer` — o que
  torna `authorize?: true` um no-op sobre ele. Era a porta dos fundos da A7: um `profissional`
  que não enxerga a agenda do colega lia a trilha inteira da clínica, com `starts_at`,
  `professional_id`, `created_by_id` e as mudanças de `obs` (que *pode* conter dado clínico,
  A-D7) de todo mundo.

  Duas regras, e nenhuma delas cabia num remendo por recurso:

    * **ler é owner·admin** — é o pedido ("tela de auditoria pro admin", §11.4). Recepção e
      profissional não leem histórico de ninguém. Vale para `:read` e `:audit_log`, os dois
      `action_type(:read)`;
    * **escrever, ninguém** — a trilha é gravada pelo próprio AshPaperTrail e por mais nada.
      Uma trilha que a aplicação pode editar não é trilha.

  ### Por que proibir a escrita não quebra a gravação

  O `CreateNewVersion` grava a versão com `authorize?: Ash.Domain.Info.authorize(domain) ==
  :always`. `Api.Scheduling` usa o default (`:by_default`), então a gravação roda com
  `authorize?: false` e **não passa por policy nenhuma** — a proibição vale só para quem chega
  de fora. Se um dia o domínio virar `authorize :always`, este `forbid_if always()` derruba a
  gravação e o teste da trilha acusa; é o alarme certo, e não um silêncio.

  ## A leitura paginada (§11.4)

  A trilha é a tabela que mais cresce do sistema; a lista de pacientes já ensinou que
  carrega-tudo vira dívida. Por isso `:audit_log` é **offset-paginada** e sai ordenada do mais
  recente para o mais antigo — com o índice `(clinic_id, version_inserted_at DESC)` (migration
  da fatia), a página lê só `offset + limit` linhas, sem varrer o histórico.

  Os filtros do §11.4 (registro, autor, período, ação) NÃO moram na ação: são **opcionais** e
  montados condicionalmente pelo domínio (`Api.Scheduling.list_audit_log/2`) via
  `query: [filter: ...]`, para o mesmo `read` servir o feed cronológico e o histórico de um
  registro só. Ficam fora daqui por um motivo concreto: `filter expr(coluna …)` referencia a
  coluna por nome, e o nome não sobrevive à higiene do `quote` do mixin (viraria variável no
  contexto de `TrailMixin`, não campo). O recorte por *tipo de recurso*
  (`appointment` × `attendance`) é escolha de qual `*.Version` paginar, também no domínio.

  A ordenação leva o `id` como desempate: sob paginação, duas versões com o mesmo
  `version_inserted_at` poderiam repetir ou sumir entre páginas sem uma ordem **total**.
  """

  defmacro __using__(_opts) do
    quote do
      actions do
        # O feed da tela de auditoria: paginada e ordenada por recência. Os filtros são do
        # domínio (ver o moduledoc), então a ação declara só a paginação e a ordem estável.
        read :audit_log do
          pagination offset?: true, countable: true, default_limit: 50, max_page_size: 200
          prepare build(sort: [version_inserted_at: :desc, id: :desc])
        end
      end

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
