defmodule Api.Messaging.Templates do
  @moduledoc """
  O texto das mensagens ao paciente (doc 52 §4), como **template + variáveis**.

  ## Por que não montar a string na hora do envio

  Porque o WhatsApp não deixa. Fora da janela de 24 h, a Meta só aceita **template HSM aprovado**,
  com variáveis posicionais e corpo fixo. Um corpo montado como string na fase 1 significaria
  reescrever este módulo inteiro na fase 2 — e o §2 do doc 52 é exatamente sobre isso: dos quatro
  eixos que mudam entre e-mail e WhatsApp, o conteúdo é um dos três em que "só muda quem envia" é
  falso.

  Nascendo assim, a fase 2 registra os mesmos nomes de template na Meta, mapeia `vars` para as
  posicionais e troca o transporte.

  ## O nome do template carrega versão

  `"confirmacao_v1"`, não `"confirmacao"`. Mudar o texto de uma mensagem já enviada mudaria o
  **histórico**: a timeline renderiza a partir do template gravado, então um texto reescrito faria
  o passado dizer outra coisa. Texto novo = `_v2`, e o `_v1` continua existindo para renderizar o
  que já saiu. É a mesma razão de `destino` ser congelado na linha.

  ## O nome da clínica é obrigatório em todo template

  Não é decoração: é o §9.1.4. A v1 vai com **um número/remetente único da Cinetra** (C11), e o
  paciente tem relação com a clínica, não com a Cinetra. A primeira linha dizer de quem é a
  mensagem é o que separa "mensagem esperada" de "quem é você?" — e é o que segura a decisão do
  número compartilhado de pé.
  """

  @templates %{
    "confirmacao_v1" => :confirmacao,
    "lembrete_v1" => :lembrete,
    "remarcacao_v1" => :remarcacao,
    "cancelamento_v1" => :cancelamento
  }

  @doc "O template vigente para um `kind`. É o que o `Dispatch` grava na mensagem."
  def para(:confirmacao), do: "confirmacao_v1"
  def para(:lembrete), do: "lembrete_v1"
  def para(:remarcacao), do: "remarcacao_v1"
  def para(:cancelamento), do: "cancelamento_v1"

  @doc "O `kind` de um template gravado — a volta de `para/1`, para a timeline."
  def kind_de(template), do: Map.get(@templates, template)

  @doc "Todos os templates conhecidos. Usado pelo teste que garante que nenhum `kind` ficou órfão."
  def conhecidos, do: Map.keys(@templates)

  @doc """
  Renderiza um template para e-mail: `%{assunto: ..., texto: ...}`.

  Variáveis esperadas em `vars` (chaves string, porque vêm de um `:map` do banco): `"clinica"`,
  `"paciente"`, `"data"`, `"hora"` e, quando há resposta a pedir, `"link"`.

  Template desconhecido devolve `:error` em vez de levantar: a timeline renderiza linhas antigas,
  e um template removido do código não pode derrubar a leitura da tela inteira.
  """
  def render_email(template, vars)

  def render_email("confirmacao_v1", v) do
    {:ok,
     %{
       assunto: "#{nome(v, "clinica")}: sua sessão de #{v["data"]} às #{v["hora"]}",
       texto: """
       Olá, #{primeiro_nome(v)}!

       Sua sessão na #{nome(v, "clinica")} está agendada para #{v["data"]} às #{v["hora"]}.
       #{confirme(v)}
       """
     }}
  end

  def render_email("lembrete_v1", v) do
    {:ok,
     %{
       assunto: "#{nome(v, "clinica")}: lembrete da sua sessão de #{v["data"]}",
       texto: """
       Olá, #{primeiro_nome(v)}!

       Passando para lembrar da sua sessão na #{nome(v, "clinica")}: #{v["data"]} às #{v["hora"]}.
       #{confirme(v)}
       """
     }}
  end

  def render_email("remarcacao_v1", v) do
    {:ok,
     %{
       assunto: "#{nome(v, "clinica")}: sua sessão mudou para #{v["data"]}",
       texto: """
       Olá, #{primeiro_nome(v)}!

       Sua sessão na #{nome(v, "clinica")} passou para #{v["data"]} às #{v["hora"]}.
       #{confirme(v)}
       """
     }}
  end

  def render_email("cancelamento_v1", v) do
    {:ok,
     %{
       assunto: "#{nome(v, "clinica")}: sua sessão de #{v["data"]} foi cancelada",
       texto: """
       Olá, #{primeiro_nome(v)}!

       Sua sessão na #{nome(v, "clinica")} em #{v["data"]} às #{v["hora"]} foi cancelada.

       Para remarcar, é só responder a quem te atende na clínica.
       """
     }}
  end

  def render_email(_desconhecido, _vars), do: :error

  # O bloco de resposta só aparece quando há link (§5). Sem ele a mensagem ainda é útil — é
  # informação —, então a ausência não é erro: é uma mensagem sem pergunta.
  defp confirme(%{"link" => link}) when is_binary(link) and link != "" do
    """

    Você pode confirmar ou pedir remarcação aqui:
    #{link}
    """
  end

  defp confirme(_vars), do: ""

  # "Olá, Maria!" e não "Olá, Maria Aparecida da Silva Santos!". O primeiro nome é como se fala
  # com alguém; o nome completo num cumprimento soa a cobrança.
  defp primeiro_nome(vars) do
    vars
    |> nome("paciente")
    |> String.split(" ", parts: 2)
    |> hd()
  end

  # Variável ausente não pode virar "Olá, !" nem derrubar o render: a mensagem já foi gravada, e
  # a timeline precisa exibi-la mesmo que um campo tenha sumido da ficha depois.
  defp nome(vars, chave) do
    case Map.get(vars, chave) do
      valor when is_binary(valor) and valor != "" -> valor
      _ -> "—"
    end
  end
end
