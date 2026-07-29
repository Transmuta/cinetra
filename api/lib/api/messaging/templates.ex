defmodule Api.Messaging.Templates do
  @moduledoc """
  O texto das mensagens ao paciente (doc 52 §4), como **template + variáveis**.

  ## Por que não montar a string na hora do envio

  Porque o WhatsApp não deixa. Fora da janela de 24 h, a Meta só aceita **template HSM aprovado**,
  com variáveis posicionais e corpo fixo. Um corpo montado como string na fase 1 significaria
  reescrever este módulo inteiro na fase 2 — e o §2 do doc 52 é exatamente sobre isso: dos quatro
  eixos que mudam entre e-mail e WhatsApp, o conteúdo é um dos três em que "só muda quem envia" é
  falso.

  Nascendo assim, a fase 2 registrou os mesmos nomes de template na Meta, mapeou `vars` para as
  posicionais e trocou o transporte.

  ## O nome do template carrega versão

  `"confirmacao_v1"`, não `"confirmacao"`. Mudar o texto de uma mensagem já enviada mudaria o
  **histórico**: a timeline renderiza a partir do template gravado, então um texto reescrito faria
  o passado dizer outra coisa. Texto novo = `_v2`, e o `_v1` continua existindo para renderizar o
  que já saiu. É a mesma razão de `destino` ser congelado na linha.

  No WhatsApp isso deixa de ser só higiene e vira **obrigação da Meta**: o nome é a chave do
  template aprovado. Reescrever o corpo de um `_v1` já aprovado sem trocar o nome faz a mensagem
  sair com o texto **antigo** (o que a Meta tem), enquanto a timeline mostra o novo — divergência
  silenciosa entre o que o paciente leu e o que a clínica vê.

  ## O nome da clínica é obrigatório em todo template

  Não é decoração: é o §9.1.4. A v1 vai com **um número/remetente único da Cinetra** (C11), e o
  paciente tem relação com a clínica, não com a Cinetra. A primeira linha dizer de quem é a
  mensagem é o que separa "mensagem esperada" de "quem é você?" — e é o que segura a decisão do
  número compartilhado de pé.

  ## A ordem das variáveis do WhatsApp é contrato, e mora aqui

  A Zernio manda `templateParams` como **lista plana**, sem nomes: cabeçalho, corpo e um valor por
  botão de URL dinâmica, nessa ordem. Se a ordem daqui divergir da ordem aprovada na Meta, a
  mensagem sai com a data no lugar do nome — e **a API aceita**, porque a contagem bate. Não há
  código de erro para esse defeito; o sintoma é um paciente confuso.

  Por isso o corpo aprovado (`:corpo`) e a ordem (`:vars`) ficam lado a lado na mesma definição, e
  a mix task que submete à Meta lê daqui. Uma fonte, não duas que se parecem.

  ## Por que o texto do WhatsApp não é igual ao do e-mail

  A Meta recusa template que **comece ou termine** com variável, e recusa duas variáveis coladas.
  O texto do e-mail é livre disso. Escrever os dois a partir de um só produziria ou um e-mail
  torto ou um template reprovado — e a reprovação tem lead time de dias para descobrir.
  """

  # A definição única de cada template: o `kind` que o origina, o texto do e-mail (que é livre) e
  # o HSM do WhatsApp (que é o que a Meta aprovou, com a ordem das posicionais).
  #
  # `botao?: true` acrescenta o botão de URL dinâmica cujo sufixo é o token de resposta (§5) — e,
  # com ele, **mais um valor no fim de `templateParams`**. Template sem pergunta a fazer
  # (cancelamento, massa de pacote) não tem botão: um "confirmar" numa sessão que não existe mais
  # é convite a clique inútil.
  @definicoes %{
    "confirmacao_v1" => %{
      kind: :confirmacao,
      idioma: "pt_BR",
      vars: ["paciente", "clinica", "data", "hora"],
      botao?: true,
      corpo: """
      Olá, {{1}}! Aqui é da {{2}}.

      Sua sessão está agendada para {{3}} às {{4}}.

      Se precisar confirmar ou remarcar, é só tocar no botão abaixo.\
      """
    },
    "lembrete_v1" => %{
      kind: :lembrete,
      idioma: "pt_BR",
      vars: ["paciente", "clinica", "data", "hora"],
      botao?: true,
      corpo: """
      Olá, {{1}}! Lembrete da {{2}}.

      Sua sessão é {{3}} às {{4}}.

      Se não puder vir, avise pelo botão abaixo.\
      """
    },
    "remarcacao_v1" => %{
      kind: :remarcacao,
      idioma: "pt_BR",
      vars: ["paciente", "clinica", "data", "hora"],
      botao?: true,
      corpo: """
      Olá, {{1}}! Sua sessão na {{2}} mudou de horário.

      Agora é {{3}} às {{4}}.

      Se o novo horário não servir, avise pelo botão abaixo.\
      """
    },
    "cancelamento_v1" => %{
      kind: :cancelamento,
      idioma: "pt_BR",
      vars: ["paciente", "clinica", "data", "hora"],
      botao?: false,
      corpo: """
      Olá, {{1}}! Sua sessão na {{2}}, em {{3}} às {{4}}, foi cancelada.

      Para remarcar, fale com a recepção da clínica.\
      """
    },
    "pacote_remarcado_v1" => %{
      kind: :pacote_remarcado,
      idioma: "pt_BR",
      vars: ["paciente", "clinica", "quantas", "pacote"],
      botao?: false,
      corpo: """
      Olá, {{1}}! Na {{2}}, {{3}} do seu pacote {{4}} mudaram de horário.

      A recepção entra em contato com os novos horários.\
      """
    },
    "pacote_cancelado_v1" => %{
      kind: :pacote_cancelado,
      idioma: "pt_BR",
      vars: ["paciente", "clinica", "quantas", "pacote"],
      botao?: false,
      corpo: """
      Olá, {{1}}! Na {{2}}, {{3}} do seu pacote {{4}} foram canceladas.

      Para remarcar, fale com a recepção da clínica.\
      """
    }
  }

  @por_kind Map.new(@definicoes, fn {nome, %{kind: kind}} -> {kind, nome} end)

  @doc "O template vigente para um `kind`. É o que o `Dispatch` grava na mensagem."
  def para(kind), do: Map.fetch!(@por_kind, kind)

  @doc "O `kind` de um template gravado — a volta de `para/1`, para a timeline."
  def kind_de(template) do
    case Map.get(@definicoes, template) do
      %{kind: kind} -> kind
      nil -> nil
    end
  end

  @doc "Todos os templates conhecidos. Usado pelo teste que garante que nenhum `kind` ficou órfão."
  def conhecidos, do: Map.keys(@definicoes)

  @doc """
  A definição HSM de um template — o que a mix task submete à Meta e o que `render_whatsapp/2`
  usa para ordenar as posicionais. `nil` para template desconhecido.
  """
  def hsm(template), do: Map.get(@definicoes, template)

  # Exemplos que acompanham a submissão. A Meta exige um por posicional, e ele precisa ter a
  # **mesma cara** do valor real: é por ele que o revisor humano entende o template. Sair da mesma
  # lista `:vars` é o que impede exemplo e ordem de divergirem.
  @exemplos %{
    "paciente" => "Maria",
    "clinica" => "Clínica Cinetra",
    "data" => "28/07/2026",
    "hora" => "14:00",
    "quantas" => "3 sessões",
    "pacote" => "Pilates 10"
  }

  @doc """
  O payload de submissão do template à Meta, via Zernio (doc 65 §3).

  Mora aqui, e não na mix task, por dois motivos: é a **mesma** definição que `render_whatsapp/2`
  usa (uma fonte, não duas que se parecem), e assim a montagem é testável sem rodar a task.

  `base_url` é o domínio do botão de resposta — congelado no template aprovado, então trocá-lo
  depois exige `_v2`.
  """
  def hsm_payload(template, base_url) do
    case hsm(template) do
      nil ->
        :error

      %{idioma: idioma, corpo: corpo, vars: nomes, botao?: botao?} ->
        {:ok,
         %{
           name: template,
           language: idioma,
           # `UTILITY` e não `MARKETING`: toda mensagem nossa nasce de um agendamento que existe
           # (`Api.Messaging.MessageKind`). A categoria errada muda o preço e a régua de
           # aprovação — e um template operacional aprovado como marketing fica sujeito ao
           # opt-out de marketing, que é outro consentimento.
           category: "UTILITY",
           components:
             [
               %{
                 type: "BODY",
                 text: corpo,
                 example: %{body_text: [Enum.map(nomes, &Map.fetch!(@exemplos, &1))]}
               }
             ] ++ botao(botao?, base_url)
         }}
    end
  end

  defp botao(false, _base), do: []

  defp botao(true, base) do
    [
      %{
        type: "BUTTONS",
        buttons: [
          %{
            type: "URL",
            text: "Confirmar ou remarcar",
            url: base <> "/confirmar/{{1}}",
            example: [base <> "/confirmar/abc123"]
          }
        ]
      }
    ]
  end

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

  def render_email("pacote_remarcado_v1", v) do
    {:ok,
     %{
       assunto: "#{nome(v, "clinica")}: #{v["quantas"]} do seu pacote mudaram de horário",
       texto: """
       Olá, #{primeiro_nome(v)}!

       Na #{nome(v, "clinica")}, #{v["quantas"]} do seu pacote #{nome(v, "pacote")} mudaram de
       horário.

       A recepção entra em contato com os novos horários.
       """
     }}
  end

  def render_email("pacote_cancelado_v1", v) do
    {:ok,
     %{
       assunto: "#{nome(v, "clinica")}: #{v["quantas"]} do seu pacote foram canceladas",
       texto: """
       Olá, #{primeiro_nome(v)}!

       Na #{nome(v, "clinica")}, #{v["quantas"]} do seu pacote #{nome(v, "pacote")} foram
       canceladas.

       Para remarcar, é só responder a quem te atende na clínica.
       """
     }}
  end

  def render_email(_desconhecido, _vars), do: :error

  @doc """
  Renderiza um template para WhatsApp: `%{nome: ..., idioma: ..., params: [...]}`.

  `params` é a lista **plana e ordenada** que a Zernio repassa à Meta — as variáveis do corpo na
  ordem em que aparecem no texto aprovado e, quando o template tem botão de resposta, o `"token"`
  no fim (é o sufixo da URL dinâmica, não a URL inteira: o domínio foi aprovado junto do template).

  Variável ausente vira `"—"` pelo mesmo motivo do e-mail, com uma diferença que importa: a Meta
  **recusa** a mensagem se a contagem de parâmetros não bater com o template aprovado. Mandar
  um travessão é feio; mandar a menos é a mensagem não sair.
  """
  def render_whatsapp(template, vars) do
    case hsm(template) do
      nil ->
        :error

      %{idioma: idioma, vars: nomes, botao?: botao?} ->
        params = Enum.map(nomes, &valor(vars, &1))

        {:ok,
         %{
           nome: template,
           idioma: idioma,
           params: if(botao?, do: params ++ [valor(vars, "token")], else: params)
         }}
    end
  end

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

  # No WhatsApp o cumprimento é a primeira posicional, então o encurtamento tem de acontecer no
  # valor — não na string do template, que a Meta congelou.
  # Higieniza **antes** de cortar o primeiro nome, não depois: "Ana\nMaria" não tem espaço, então
  # o corte sozinho devolveria o nome inteiro com a quebra dentro — exatamente o valor que a Meta
  # recusa. Colapsar primeiro faz o corte enxergar o espaço que passou a existir.
  defp valor(vars, "paciente"), do: vars |> nome("paciente") |> higienizar() |> primeiro()
  defp valor(vars, chave), do: vars |> nome(chave) |> higienizar()

  defp primeiro(nome), do: nome |> String.split(" ", parts: 2) |> hd()

  # A Meta **recusa** parâmetro de template com quebra de linha, tab ou 4+ espaços seguidos
  # (família de erro 132xxx). O dado vem da ficha, que é texto livre: um nome colado de PDF ou de
  # planilha carrega `\n` sem ninguém ver.
  #
  # O efeito de não fazer isto é o pior tipo de defeito — silencioso e mal-endereçado: a mensagem
  # **daquele** paciente falha sempre, e o motivo que chega à recepção é "Template de WhatsApp não
  # aprovado ou fora do padrão", que manda olhar o template. O template está certo; o nome é que
  # tem uma quebra de linha invisível na tela.
  #
  # Colapsar, e não truncar: "Ana\nMaria" vira "Ana Maria" — o dado continua legível. E só no
  # WhatsApp: no e-mail a restrição não existe, e higienizar lá seria reescrever o texto do
  # paciente sem motivo.
  defp higienizar(valor), do: valor |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Variável ausente não pode virar "Olá, !" nem derrubar o render: a mensagem já foi gravada, e
  # a timeline precisa exibi-la mesmo que um campo tenha sumido da ficha depois.
  defp nome(vars, chave) do
    case Map.get(vars, chave) do
      valor when is_binary(valor) and valor != "" -> valor
      valor when is_integer(valor) -> to_string(valor)
      _ -> "—"
    end
  end
end
