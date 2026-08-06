defmodule Api.LogRedacao do
  @moduledoc """
  Troca por `"***"` o valor de todo campo sensível que entrar no log (ADR-025).

  ## O que esta camada está protegendo, e do quê

  O log **não** é o banco. Ele vive 30 dias no Loki, fora do Postgres, **sem RLS**, e é lido por
  uma conta de Grafana compartilhada por mais de uma pessoa, sem trilha de quem leu o quê (doc 95,
  R-M17). Levar payload de request e corpo de response para lá — que é o que o ADR-025 decidiu —
  só se sustenta com esta camada na frente.

  ## Blocklist, e o que isso custa

  A lista abaixo é do que **não pode** sair; o resto sai em claro. Foi a decisão tomada, e ela
  compra legibilidade na investigação (`nascimento`, `convenio` e `status` visíveis contam a
  história de um 422) ao preço de **errar aberto**: um campo novo em `Patient` que ninguém
  acrescentar aqui vai para o Loki em claro, e nada avisa.

  Três coisas seguram esse risco, e nenhuma delas sozinha basta:

    1. `log_redacao_test.exs` cobra a lista contra os atributos reais dos recursos e contra o
       `Api.Audit.Sensiveis` — campo que a trilha protege e o log não reprova a suíte;
    2. a redação por **forma do valor** no Alloy (CPF, e-mail, telefone) continua rodando na
       coleta, e pega o que passou por aqui com nome de chave inesperado;
    3. o escopo é só 4xx/5xx — requisição bem-sucedida não carrega payload nenhum.

  ## Por que na origem, e não só no formatter

  Os dois. `redigir/1` roda no `ApiWeb.RequestLogger`, antes de o valor entrar no `Logger` — é a
  primeira camada do doc 05 §2.4, a que impede o dado de existir no pipeline. E o módulo também
  implementa `LoggerJSON.Redactor`, ligado em `config/prod.exs`, o que faz **toda** linha do
  sistema passar pela mesma lista: um `Logger.info("...", cpf: valor)` escrito daqui a seis meses
  em outro ponto do código sai redigido sem que ninguém precise lembrar.
  """

  @behaviour LoggerJSON.Redactor

  @marca "***"

  # Teto por texto. Uma mensagem de erro de provider ou um `inspect` de struct grande entram aqui
  # sem cerimônia; sem teto, uma linha só consome o que a retenção reservou para um dia.
  @max_texto 200

  # Teto do campo inteiro, depois de redigido. Acima disto o campo vira marcador: um GET de agenda
  # recusado carrega centenas de compromissos, e a linha de log deixaria de ser linha.
  @max_campo 4096

  # A lista. Agrupada por natureza porque é assim que ela é revisada — e a revisão é o único
  # mecanismo que uma blocklist tem.
  @identidade ~w[nome nome_social nome_exibicao name responsavel razao_social
                 emergencia_nome emergencia_parentesco]

  @documento ~w[cpf rg cnpj crm crefito carteirinha registro registro_uf]

  @contato ~w[tel telefone celular whatsapp phone email e_mail destino]

  @endereco ~w[cep endereco numero complemento bairro cidade uf]

  # Perfil e dado clínico. `tags` está aqui **de propósito**, e diverge da decisão tomada para a
  # trilha de auditoria (`Api.Audit.Sensiveis`), que as deixa em claro. A razão de lá não vale
  # aqui: naquele caso o argumento foi "quem lê o diff já podia ler o campo", porque a trilha é
  # owner·admin e roda sob RLS, por clínica. O Loki não tem nenhuma das duas coisas — quem abre o
  # Grafana lê o de todas as clínicas. `tags` são condições clínicas em texto puro (D16/D18), o
  # dado do Art. 11 mais sensível que o sistema guarda.
  @perfil ~w[tags nascimento genero estado_civil profissao empresa medico convenio
             convenio_validade como_conheceu especialidades vars]

  @financeiro ~w[banco agencia conta conta_tipo pix]

  @credencial ~w[token senha password secret authorization api_key apikey signature assinatura
                 refresh_token access_token]

  @sensiveis MapSet.new(
               @identidade ++
                 @documento ++
                 @contato ++ @endereco ++ @perfil ++ @financeiro ++ @credencial
             )

  # `code` só é credencial na QUERY — é o authorization code do callback do Google. No corpo de
  # uma resposta, `code` é o código do erro de validação (`{"field":"cpf","code":"formato_invalido"}`),
  # que é justamente o que o ADR-025 quer poder ler. Redigir os dois com a mesma regra apagaria o
  # motivo da recusa, que é o único ganho da decisão.
  @sensiveis_query MapSet.put(@sensiveis, "code")

  @doc "Este nome de campo é redigido?"
  @spec sensivel?(atom() | String.t(), :corpo | :query) :: boolean()
  def sensivel?(chave, contexto \\ :corpo)

  def sensivel?(chave, contexto) when is_atom(chave),
    do: chave |> Atom.to_string() |> sensivel?(contexto)

  def sensivel?(chave, contexto) when is_binary(chave) do
    lista = if contexto == :query, do: @sensiveis_query, else: @sensiveis
    chave = String.downcase(chave)

    # Casa a chave inteira **ou qualquer segmento** dela.
    #
    # Só o casamento exato deixava `emergencia_tel` passar em claro — a lista teria de prever cada
    # composição (`emergencia_tel`, `responsavel_cpf`, `titular_email`…), e prever composição é
    # exatamente o que uma blocklist não consegue fazer.
    #
    # Segmento, e não substring: `hotel` e `detalhe` contêm "tel" e "tal" e não podem ser
    # redigidos; `emergencia_tel` quebra em `["emergencia", "tel"]` e casa. O custo é falso
    # positivo em campo composto legítimo (`numero_sessoes` vira `"***"`), que custa legibilidade
    # e não vaza nada — a troca certa nesta direção.
    MapSet.member?(lista, chave) or
      Enum.any?(String.split(chave, "_"), &MapSet.member?(lista, &1))
  end

  def sensivel?(_chave, _contexto), do: false

  @doc """
  Redige um payload para virar campo do log.

  Devolve `nil` para o que não vale uma chave na linha: mapa vazio, corpo não lido pelo
  `Plug.Parsers`, `nil`.
  """
  @spec redigir(term(), :corpo | :query) :: map() | nil
  def redigir(dado, contexto \\ :corpo)
  def redigir(nil, _contexto), do: nil
  def redigir(%Plug.Conn.Unfetched{}, _contexto), do: nil
  def redigir(mapa, _contexto) when map_size(mapa) == 0, do: nil

  def redigir(mapa, contexto) when is_map(mapa) do
    mapa |> percorrer(contexto) |> limitar()
  end

  def redigir(_outro, _contexto), do: nil

  @doc """
  Redige o corpo de uma resposta.

  JSON vira mapa redigido — é o que permite `| json` alcançar `response_errors_field` no Loki, e
  é o que preserva o **motivo** da recusa (`field`, `code`) enquanto apaga o valor recusado.
  Corpo que não é JSON vira texto truncado.
  """
  @spec resposta(iodata() | nil) :: map() | String.t() | nil
  def resposta(nil), do: nil
  def resposta(""), do: nil

  def resposta(corpo) when is_binary(corpo) or is_list(corpo) do
    texto = IO.iodata_to_binary(corpo)

    case Jason.decode(texto) do
      {:ok, dado} when is_map(dado) or is_list(dado) -> dado |> percorrer(:corpo) |> limitar()
      _ -> truncar(texto)
    end
  rescue
    # Corpo binário (um PDF, um zip) não é iodata válida para `to_binary` em todo caso.
    _ -> nil
  end

  def resposta(_outro), do: nil

  @impl LoggerJSON.Redactor
  def new(opts), do: {__MODULE__, opts}

  @impl LoggerJSON.Redactor
  def redact(chave, valor, _opts) do
    if sensivel?(chave), do: @marca, else: valor
  end

  # ---- por dentro -------------------------------------------------------------------------

  defp percorrer(%Plug.Upload{} = upload, _contexto),
    do: %{arquivo: upload.filename, tipo: upload.content_type}

  defp percorrer(%_{} = struct, _contexto), do: struct |> inspect() |> truncar()

  defp percorrer(mapa, contexto) when is_map(mapa) do
    Map.new(mapa, fn {chave, valor} ->
      if sensivel?(chave, contexto),
        do: {chave, @marca},
        else: {chave, percorrer(valor, contexto)}
    end)
  end

  defp percorrer(lista, contexto) when is_list(lista),
    do: Enum.map(lista, &percorrer(&1, contexto))

  defp percorrer(texto, _contexto) when is_binary(texto), do: truncar(texto)
  defp percorrer(outro, _contexto), do: outro

  defp truncar(texto) when byte_size(texto) <= @max_texto, do: texto

  defp truncar(texto) do
    cortado = binary_part(texto, 0, @max_texto)
    "#{cortado}…[+#{byte_size(texto) - @max_texto}]"
  end

  # O teto do campo é medido no JSON, e não no mapa, porque é o JSON que ocupa a linha e a
  # retenção. Medir o mapa (`map_size`) diria que 3 chaves cabem, com uma delas trazendo 400 KB.
  defp limitar(dado) do
    case Jason.encode(dado) do
      {:ok, json} when byte_size(json) > @max_campo ->
        %{truncado: true, bytes: byte_size(json)}

      {:ok, _json} ->
        dado

      # Impossível de serializar (um PID, uma referência dentro do mapa) não vira linha: o
      # formatter estouraria depois, e um formatter que estoura derruba a linha inteira.
      {:error, _erro} ->
        %{truncado: true, bytes: 0}
    end
  end
end
