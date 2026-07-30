defmodule Api.Audit.Sensiveis do
  @moduledoc """
  Quais campos entram na trilha **sem o valor** (doc 63, D-Aud4).

  O `06 §4` tem um aviso escrito para o que esta lista evita: *"o diff sobre um campo sensível
  não pode guardar o valor em claro, senão a trilha de auditoria vira a maior fuga de dado do
  sistema"*. Sem ela, ligar a trilha em `Patient` e `Professional` faria CPF, RG e conta bancária
  passarem a existir em **duas** tabelas — e a segunda é append-only e não tem tela de correção.

  O que fica registrado de um campo daqui é `%{field: "pix", redacted: true}`: *que* mudou,
  *quem* mudou e *quando*. **Não** para qual valor.

  ## Por que não é `ignore_attributes`

  Ignorar o campo era a saída simples e mata o caso de uso: a troca do PIX é justamente o evento
  que se quer auditar (é o único campo do sistema onde a alteração tem efeito financeiro direto).
  Redigir preserva o evento e descarta só o payload.

  ## Por que na escrita, e não na leitura

  Um filtro na leitura protegeria a tela e deixaria o valor **gravado** — proteção que já chegou
  tarde, porque quem lê o banco (backup, réplica, dump de suporte) não passa pela tela. Aqui o
  valor nunca é gravado.

  ## O que NÃO está aqui, e é decisão registrada (2026-07-28)

  `tags`, `medico` e `crm` do paciente ficam **em claro** na trilha. As `tags` são "condições
  clínicas em texto puro" pela decisão da fatia de Pacientes (D16/D18) — dado do Art. 11 da LGPD,
  e portanto a informação mais sensível que o diff carrega:

      {"field": "tags", "from": ["HIV+"], "to": ["hepatite C"]}

  O bate-volta levantou a assimetria (redige-se CPF, que é identificador, e não a condição
  clínica, que é dado de saúde) e **a exposição foi aceita pelo decisor**. O raciocínio que a
  sustenta: não há escalação de privilégio — a trilha é owner·admin e a ficha é legível por todo
  membro, então quem lê o diff já podia ler o campo. O que se aceita, de olhos abertos, é o custo
  de **minimização**: o valor passa a existir numa segunda tabela, append-only, sem tela de
  correção, retida por 90 dias — e a eliminação do titular (F8/D-1) terá de alcançá-la.

  Reverter é acrescentar os três à lista abaixo; `sensiveis_test.exs` cobra a mudança nos dois
  sentidos.

  ## Manutenção

  A lista é por recurso e explícita. Campo novo em ficha de paciente ou profissional **não** é
  redigido por default: é decisão de quem o adiciona, e `test/api/audit/sensiveis_test.exs`
  existe para que a decisão seja consciente e não um esquecimento — ele compara a lista com a
  decisão nos dois sentidos e confere que todo campo listado existe mesmo no recurso.
  """

  @sensiveis %{
    patient: [:cpf, :rg],
    professional: [:cpf, :rg, :cnpj, :banco, :agencia, :conta, :conta_tipo, :pix]
  }

  @doc "Os campos redigidos de um recurso da trilha (lista vazia se não há)."
  @spec campos(atom()) :: [atom()]
  def campos(resource), do: Map.get(@sensiveis, resource, [])

  @doc "Este campo deste recurso vai para a trilha sem o valor?"
  @spec redigir?(atom(), atom()) :: boolean()
  def redigir?(resource, field), do: field in campos(resource)

  @doc "O mapa inteiro — para o teste que cobra a decisão consciente."
  @spec todos() :: %{atom() => [atom()]}
  def todos, do: @sensiveis
end
