defmodule Api.Scheduling.Appointment.Checks.CreatingEncaixe do
  @moduledoc """
  Condição de policy: **este changeset está pedindo um encaixe?**

  Serve para condicionar a policy da A9 — só `owner`·`admin`·`recepcao` criam encaixe. Sem ela,
  `encaixe` era só um booleano no corpo do POST: o papel menos privilegiado desligava, sozinho,
  o predicado parcial da exclusion constraint (`WHERE encaixe = false AND status <> 'cancelado'`)
  e com ele a única garantia real contra dupla-marcação (A5). Um opt-out de proteção pelo
  cliente.

  Lê o **argumento** e não o atributo de propósito: `encaixe` chega como argumento da ação
  `:schedule` e vira atributo num `change set_attribute/2`; policies e changes não têm ordem
  garantida entre si, então perguntar pelo atributo poderia ler `false` num changeset que vai
  gravar `true`. O argumento é o que o cliente pediu, e é o que a autorização precisa julgar.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "a ação está criando um encaixe"

  @impl true
  def match?(_actor, %{subject: %Ash.Changeset{} = changeset}, _opts) do
    Ash.Changeset.get_argument(changeset, :encaixe) == true
  end
end
