defmodule Api.Records.Patient.Validations.CampoValido do
  @moduledoc """
  AN-11 / HOM-012 (doc 64, D10): CPF, e-mail e nascimento **barram no salvar** quando vêm
  preenchidos e inválidos — dado limpo vale o atrito no balcão, e e-mail errado passou a custar
  confirmação não entregue (doc 52). Era a única régua que barrava na ficha (o duplicado só
  avisava); desde 2026-07-29 a **repetição** também barra, pelas `identities` do recurso.

  Só valida o que veio: os três campos continuam **opcionais** (obrigatório é nome + telefone,
  `TelObrigatorio`). A régua de cada um:

    * **`:cpf`** — dígito verificador (`Api.Cpf`), rejeitando sequência repetida;
    * **`:email`** — a forma mínima `algo@algo.tld`, a mesma que o Ash sugere; mais que isso
      (MX, RFC completa) reprovaria endereço real sem ganho — quem confirma é o envio;
    * **`:nascimento`** — nem futuro (com 1 dia de folga: a data é local e o relógio daqui é
      UTC), nem antes de 1900 — os dois erros de digitação que uma `:date` bem-formada deixa
      passar.

  Um módulo com `campo:` em vez de três módulos: as três checagens têm a mesma moldura (ausente
  passa; presente confere) e moram na mesma ação — três arquivos divergiriam na moldura antes de
  divergirem na régua. Não é atômica pela mesma razão da `TelObrigatorio`: a conta não se
  expressa em SQL, e o controller já faz fetch-then-update.
  """
  use Ash.Resource.Validation

  @campos [:cpf, :email, :nascimento]

  @email_re ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @impl true
  def init(opts) do
    if opts[:campo] in @campos,
      do: {:ok, opts},
      else: {:error, "campo deve ser um de #{inspect(@campos)}"}
  end

  @impl true
  def validate(changeset, opts, _context) do
    campo = opts[:campo]

    case Ash.Changeset.get_attribute(changeset, campo) do
      nil -> :ok
      "" -> :ok
      valor -> conferir(campo, valor)
    end
  end

  defp conferir(:cpf, valor) do
    if Api.Cpf.valid?(valor),
      do: :ok,
      else: {:error, field: :cpf, message: "CPF inválido — confira os dígitos"}
  end

  defp conferir(:email, valor) when is_binary(valor) do
    if String.match?(valor, @email_re),
      do: :ok,
      else: {:error, field: :email, message: "E-mail inválido — use nome@dominio"}
  end

  defp conferir(:nascimento, %Date{} = data) do
    cond do
      Date.compare(data, Date.add(Date.utc_today(), 1)) == :gt ->
        {:error, field: :nascimento, message: "Data de nascimento no futuro"}

      data.year < 1900 ->
        {:error, field: :nascimento, message: "Data de nascimento inválida"}

      true ->
        :ok
    end
  end

  # Tipo inesperado (o cast do Ash já barrou antes; isto é cinto de segurança).
  defp conferir(_campo, _valor), do: :ok
end
