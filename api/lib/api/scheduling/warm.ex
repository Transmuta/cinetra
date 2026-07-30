defmodule Api.Scheduling.Warm do
  @moduledoc """
  O **invariante de um lote de escritas**, carregado uma vez e carregado no contexto do changeset.

  ## O problema que resolve

  Cada ação de agendamento valida o mundo de novo — e está certa: uma escrita solta não pode
  confiar em nada que não tenha lido. Mas quando N escritas rodam **dentro da mesma transação**
  (a massa por pacote, doc 41 etapa 3), as leituras que não mudam entre elas — a clínica, o
  profissional, o expediente semanal, as exceções da janela — viram custo multiplicado por N.

  Medido no bate-volta da Onda 3 (doc 43 §5a): 39,4 queries por sessão numa massa de 40, das quais
  só 4 eram escrita; para 10 sessões, `40x appointment_types`, `20x professionals`,
  `20x schedule_exceptions`, `10x clinics`, `10x clinic_hours`, `10x professional_hours` — sempre
  as mesmas linhas. Em produção, com o banco na rede, isso é ~2,3 s de **transação única**
  segurando conexão do pool e os locks da exclusion constraint.

  ## Como funciona

  Quem abre o lote monta o warm com `build/4` e passa `context: %{warm: warm}` nas opções da ação.
  Os leitores (hoje `CheckAvailability`) perguntam primeiro aqui; em `:miss` seguem pelo caminho
  normal — o warm é **atalho**, nunca autoridade. Uma ação chamada sem warm (o caso comum, uma
  sessão de cada vez) se comporta exatamente como antes.

  ## Por que é seguro

  O que entra aqui é o que **não muda dentro da transação do lote**: a transação já viu um snapshot
  consistente, e ninguém de fora escreve nela. O que varia por sessão — o bloco, as presenças, a
  ocupação da turma, o conflito de horário — **não** entra e continua sendo lido a cada escrita.
  Essa é a linha: warm é para invariante, não para estado que a própria massa altera.

  As fontes de disponibilidade vêm de `Api.Scheduling.load_availability_window/4`, o mesmo
  carregador em janela que a agenda usa desde o achado (f) do doc 26 — não há segunda escrita da
  regra de expediente aqui, só um recorte já pronto sendo reaproveitado.
  """

  alias Api.Scheduling

  @doc """
  Monta o warm de um lote. Opções:

    * `:profissionais` / `:de` / `:ate` — para quem e em que janela de datas carregar o expediente;
    * `:tipos` — ids de tipo de atendimento que o lote usa (duração, capacidade, arquivado);
    * `:pacientes` — ids de paciente que o lote agenda (existe nesta clínica? está ativo?);
    * `:pacotes` — mapa `%{package_id => patient_id}` já conhecido do lote (de quem é o pacote).

  Devolve `nil` quando não há o que aquecer (sem profissionais) ou quando o carregador recusa
  (profissional inexistente) — aí as ações seguem pelo caminho normal e o erro aparece onde sempre
  apareceu, com a mensagem de sempre.
  """
  def build(clinic_id, opts) when is_binary(clinic_id) do
    ids = opts |> Keyword.get(:profissionais, []) |> Enum.uniq()
    from = Keyword.fetch!(opts, :de)
    to = Keyword.fetch!(opts, :ate)

    with [_ | _] <- ids,
         {:ok, pares} <- Scheduling.load_availability_window(clinic_id, ids, from, to) do
      # As duas leituras de catálogo numa transação só (a GUC de tenant é `SET LOCAL`): abrir uma
      # por lista custaria dois `begin`/`set_config`/`commit` para trazer duas linhas.
      {:ok, {tipos, pacientes}} =
        Api.Repo.with_clinic(clinic_id, fn ->
          {por_id(&Api.Directory.list_appointment_types!/1, clinic_id, opts[:tipos]),
           por_id(&Api.Records.list_patients!/1, clinic_id, opts[:pacientes])}
        end)

      %{
        clinic_id: clinic_id,
        clinic: Scheduling.load_clinic(clinic_id),
        janela: Date.range(from, to),
        sources: Map.new(pares, fn {prof, sources} -> {prof.id, {prof, sources}} end),
        tipos: tipos,
        pacientes: pacientes,
        pacotes: Keyword.get(opts, :pacotes, %{})
      }
    else
      _ -> nil
    end
  end

  defp por_id(_listar, _clinic_id, nil), do: %{}
  defp por_id(_listar, _clinic_id, []), do: %{}

  defp por_id(listar, clinic_id, ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    listar.(tenant: clinic_id, authorize?: false, query: [filter: [id: [in: ids]]])
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  As opções da ação com o warm no contexto (no-op quando não há warm). Faz **merge** com um
  `:context` que já venha nas opções — o contexto é de todo mundo, não só nosso.
  """
  def opts(opts, nil), do: opts

  def opts(opts, warm) do
    contexto = opts |> Keyword.get(:context, %{}) |> Map.put(:warm, warm)
    Keyword.put(opts, :context, contexto)
  end

  @doc "A clínica do lote, se o changeset trouxer warm dela. `:miss` manda ler."
  def clinic(changeset, clinic_id) do
    case warm(changeset) do
      %{clinic_id: ^clinic_id, clinic: %{} = clinic} -> {:ok, clinic}
      _ -> :miss
    end
  end

  @doc """
  `{:ok, professional, sources}` para um profissional numa data **dentro da janela** do lote.

  Fora da janela é `:miss` de propósito: as fontes foram lidas com as exceções daquele intervalo,
  e um dia de fora não teria a exceção dele carregada — o veredito sairia "aberto" onde a clínica
  está fechada. Errar para o lado de reler é a única direção segura aqui.
  """
  def sources(changeset, clinic_id, professional_id, %Date{} = date) do
    with %{clinic_id: ^clinic_id, janela: janela, sources: sources} <- warm(changeset),
         true <- date in janela,
         {:ok, {professional, srcs}} <- Map.fetch(sources, professional_id) do
      {:ok, professional, srcs}
    else
      _ -> :miss
    end
  end

  @doc "O profissional do lote (`{:ok, professional}`), já lido com as fontes de expediente."
  def profissional(changeset, clinic_id, professional_id) do
    case warm(changeset) do
      %{clinic_id: ^clinic_id, sources: %{^professional_id => {prof, _srcs}}} -> {:ok, prof}
      _ -> :miss
    end
  end

  @doc """
  O tipo de atendimento do lote (`{:ok, tipo}`), se estiver aquecido. `:miss` manda ler.
  """
  def tipo(changeset, clinic_id, type_id) do
    case warm(changeset) do
      %{clinic_id: ^clinic_id, tipos: %{^type_id => tipo}} -> {:ok, tipo}
      _ -> :miss
    end
  end

  @doc """
  O `package_id` é deste paciente? (`:ok` · `:nao` · `:miss`).

  O que aquece esta resposta não é uma leitura nova: é o vínculo que a massa **já tem em mãos** —
  a presença carregada traz `package_id` e `patient_id`, e esse par só existe porque a criação
  passou por esta mesma validação. `:miss` (pacote diferente do lote) cai na consulta de sempre.
  """
  def pacote_do_paciente?(portador, clinic_id, package_id, patient_id) do
    case warm(portador) do
      %{clinic_id: ^clinic_id, pacotes: %{^package_id => ^patient_id}} -> :ok
      %{clinic_id: ^clinic_id, pacotes: %{^package_id => _outro}} -> :nao
      _ -> :miss
    end
  end

  @doc """
  Os pacientes do lote (`{:ok, [paciente]}`), **só quando todos** os `ids` estão aquecidos —
  a resposta parcial não serve para quem pergunta "algum destes é de fora?".
  """
  def pacientes(changeset, clinic_id, ids) do
    with %{clinic_id: ^clinic_id, pacientes: pacientes} <- warm(changeset),
         encontrados = Enum.map(ids, &Map.get(pacientes, &1)),
         true <- Enum.all?(encontrados, &(not is_nil(&1))) do
      {:ok, encontrados}
    else
      _ -> :miss
    end
  end

  # Os leitores chegam por dois canais: o changeset da ação (`%{context: …}`) e as **opções** de
  # uma chamada que ainda não virou changeset (o `find_turma/2` do domínio, que decide se a sessão
  # funde numa turma existente antes de montar changeset nenhum).
  defp warm(%{context: %{warm: %{} = warm}}), do: warm

  defp warm(opts) when is_list(opts) do
    case Keyword.get(opts, :context) do
      %{warm: %{} = warm} -> warm
      _ -> nil
    end
  end

  defp warm(_outro), do: nil
end
