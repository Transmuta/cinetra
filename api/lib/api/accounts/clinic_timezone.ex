defmodule Api.Accounts.ClinicTimezone do
  @moduledoc """
  O fuso da clínica (ADR-009) cacheado em `:persistent_term` — D-K do doc 30 §4.

  ## Por que cachear justamente isto

  O fuso entra em todo caminho quente: cada escrita da agenda passa pelo `AgendaNotifier` (que
  precisa do dia **local** para escolher o tópico), cada janela lida pela fronteira converte
  UTC↔local, cada fan-out de notificação formata a hora. Era um PK-hit na `clinics` por escrita
  e por leitura — barato isolado, e comprado toda vez.

  É o candidato certo porque o dado é **quase imutável**: muda quando um owner troca o fuso da
  clínica, o que acontece perto de nunca. `cap_turma_padrao`/`slot_minutos` moram na mesma linha
  e **não** entram aqui de propósito: eles alimentam validação de escrita, e valor de validação
  servido de cache é um jeito de aceitar o que já foi proibido.

  ## A invalidação, que é o que realmente importa

  Cache sem invalidação transforma "mudei o fuso" num bug que só some com restart. Duas pontas:

    * **local** — `invalidate/1` apaga na hora, chamado pela própria ação
      (`Api.Accounts.Clinic.Changes.InvalidateTimezoneCache`), de modo que a leitura seguinte
      no mesmo nó já enxerga o valor novo. Sem isso a correção dependeria de mensagem, e o
      teste (e a tela) veria o valor velho por uma janela;
    * **entre nós** — `:persistent_term` é por-nó, e o app roda com `DNSCluster`. Por isso a
      invalidação também sai num broadcast, e este processo, em cada nó, apaga a chave ao
      recebê-lo. Sem clustering o broadcast é entregue só localmente e nada disso muda.

  Cachear negativo não acontece: clínica inexistente levanta (é `get_clinic!`), e nada é
  gravado — a próxima chamada tenta de novo em vez de servir "não existe" para sempre.
  """
  use GenServer

  @topic "clinic_timezone"

  @doc "O fuso da clínica, do cache ou do banco."
  @spec fetch(Ecto.UUID.t()) :: String.t()
  def fetch(clinic_id) when is_binary(clinic_id) do
    case :persistent_term.get(key(clinic_id), :miss) do
      :miss ->
        tz = Api.Accounts.get_clinic!(clinic_id, authorize?: false).timezone
        :persistent_term.put(key(clinic_id), tz)
        tz

      tz ->
        tz
    end
  end

  @doc """
  Apaga o fuso desta clínica do cache — aqui e nos outros nós.

  Chamada pela ação que escreve na clínica. Apagar (em vez de reescrever com o valor novo) é o
  que mantém o banco como fonte de verdade: a próxima leitura vai lá.
  """
  @spec invalidate(Ecto.UUID.t()) :: :ok
  def invalidate(clinic_id) when is_binary(clinic_id) do
    :persistent_term.erase(key(clinic_id))
    Phoenix.PubSub.broadcast(Api.PubSub, @topic, {:invalidate, clinic_id})
  end

  @doc "Espera este processo drenar o que já chegou. Existe para o teste não correr com o PubSub."
  def sync, do: GenServer.call(__MODULE__, :sync)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    :ok = Phoenix.PubSub.subscribe(Api.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:invalidate, clinic_id}, state) do
    :persistent_term.erase(key(clinic_id))
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  defp key(clinic_id), do: {__MODULE__, clinic_id}
end
