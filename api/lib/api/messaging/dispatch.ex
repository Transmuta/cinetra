defmodule Api.Messaging.Dispatch do
  @moduledoc """
  **O único lugar que decide se uma mensagem sai, e por onde** (doc 52 §10.3).

  Espalhar essa decisão por gatilho é como se manda mensagem para quem pediu para parar: são
  quatro perguntas, na ordem, e basta um caminho esquecer uma delas.

      consentimento na ficha? → tem destino? → pediu para parar? → qual canal?

  Toda a razão de este módulo existir é ser chamado pelos **dois** lados:

    * o envio (manual, gatilho de criação, cron) — que precisa saber se manda;
    * a **leitura** da timeline — que precisa explicar por que *não* mandou (§6). O `:sem_canal`
      da tela não é uma linha em `Message`; é a ausência dela, e quem a explica é `avaliar/2`.

  Duas implementações da mesma regra divergiriam no primeiro ajuste, e a divergência apareceria
  como "a tela diz que não tem e-mail, mas o e-mail saiu".

  ## A ordem dos canais, e a saída que ela não pode virar (§10.4)

  WhatsApp é o padrão e o e-mail é a reserva (C8). Mas a reserva distingue **por que** o canal
  preferido não serviu:

    * sem telefone, ou transporte indisponível → cai para o e-mail;
    * **opt-out explícito** → **não cai**. Ele não disse "prefiro e-mail", disse *pare*. Cair para
      a reserva depois de um "SAIR" é tecnicamente correto e, do lado de lá, parece deboche.

  Por isso todo `OptOut` é explícito por construção: falha técnica (número inválido, bounce) nunca
  gera opt-out — gera falha na mensagem, que é outra coisa.

  ## Fase 1: sem WhatsApp, e isso não é um `if` espalhado

  `Api.Messaging.Transport.disponivel?/1` responde por canal. Na fase 1 o WhatsApp responde
  `false` e a resolução cai para o e-mail pelo caminho normal — o mesmo caminho de "paciente sem
  telefone". A fase 2 liga o transporte e nada aqui muda.
  """
  require Logger

  alias Api.Messaging
  alias Api.Messaging.Templates
  alias Api.Messaging.Transport

  @typedoc """
  Por que uma mensagem não sai. São os três textos do §6, e a fronteira os traduz para a tela:

    * `:sem_consentimento` — a ficha não autoriza comunicação;
    * `:sem_contato` — não há e-mail nem telefone utilizável;
    * `:opt_out` — o paciente pediu para parar.
  """
  @type motivo :: :sem_consentimento | :sem_contato | :opt_out

  @doc """
  Este paciente receberia uma mensagem agora? Por qual canal, e em qual destino?

  **Não escreve nada** — é a pergunta, não o envio. É o que a timeline usa para explicar o
  silêncio, e o que o `dispatch/4` usa antes de gravar.
  """
  @spec avaliar(map(), keyword()) :: {:ok, atom(), String.t()} | {:skip, motivo()}
  def avaliar(patient, opts \\ []) do
    if consentiu?(patient) do
      escolher_canal(patient, Keyword.get(opts, :clinic_id))
    else
      {:skip, :sem_consentimento}
    end
  end

  # A ordem de preferência (C8), com a regra do §10.4 embutida: o opt-out do canal preferido
  # **interrompe**, não cai para o próximo.
  defp escolher_canal(patient, clinic_id) do
    case candidatos(patient) do
      [] ->
        {:skip, :sem_contato}

      [{canal, destino} | resto] ->
        if Messaging.opted_out?(canal, destino, clinic_id) do
          # Aqui está o §10.4. Não é `escolher_canal(resto)`: quem pediu para parar pediu para
          # parar, e a reserva não pode virar contorno.
          {:skip, :opt_out}
        else
          _ = resto
          {:ok, canal, destino}
        end
    end
  end

  # Os canais que este paciente **poderia** receber, em ordem de preferência. Um canal só entra
  # se tem destino na ficha E transporte de pé — é o mesmo teste para "paciente sem telefone" e
  # para "WhatsApp ainda não existe" (fase 1), de propósito.
  defp candidatos(patient) do
    [{:whatsapp, normalizar(:whatsapp, patient.tel)}, {:email, normalizar(:email, patient.email)}]
    |> Enum.filter(fn {canal, destino} -> destino != nil and Transport.disponivel?(canal) end)
  end

  @doc """
  Normaliza um destino para o formato em que ele é **comparado** (o `OptOut` casa por igualdade).

  E-mail vira minúsculas com espaços fora. Telefone vira E.164 brasileiro: só dígitos, com `+55`
  quando o número tem cara de nacional. Número curto demais para ser telefone vira `nil` — melhor
  "sem contato" (que a tela mostra e alguém corrige) do que uma tentativa de envio para lixo.
  """
  def normalizar(canal, valor)

  def normalizar(_canal, nil), do: nil

  def normalizar(:email, valor) when is_binary(valor) do
    case valor |> String.trim() |> String.downcase() do
      "" -> nil
      # Sem regex de validação de e-mail: elas erram (endereços válidos existem em formas
      # improváveis) e quem valida de verdade é o provider, que devolve `bounced`. O que se
      # exige aqui é o mínimo que distingue endereço de campo preenchido errado.
      email -> if String.contains?(email, "@"), do: email, else: nil
    end
  end

  def normalizar(:whatsapp, valor) when is_binary(valor) do
    digitos = String.replace(valor, ~r/\D/, "")

    cond do
      # Já veio com o código do país (55 + DDD + 8 ou 9 dígitos).
      byte_size(digitos) in 12..13 and String.starts_with?(digitos, "55") -> "+" <> digitos
      # DDD + número, como se digita no Brasil.
      byte_size(digitos) in 10..11 -> "+55" <> digitos
      true -> nil
    end
  end

  @doc """
  Grava a mensagem e enfileira o envio — ou explica por que não.

  Devolve `{:ok, message}` ou `{:skip, motivo}`. **Nunca levanta por motivo de negócio**: quem
  chama é o gatilho de criação de agendamento e o cron, e nenhum dos dois pode falhar porque um
  paciente não tem e-mail.

  Recebe a `attendance` já com `patient` e `appointment` carregados, e a `clinic` — quem chama
  costuma ter as três à mão, e lê-las aqui de novo seria N+1 no caminho do cron.
  """
  @spec dispatch(map(), map(), map(), atom(), keyword()) :: {:ok, map()} | {:skip, motivo()}
  def dispatch(clinic, attendance, patient, kind, opts \\ []) do
    case avaliar(patient, clinic_id: clinic.id) do
      {:skip, motivo} ->
        {:skip, motivo}

      {:ok, canal, destino} ->
        {:ok, gravar_e_enfileirar(clinic, attendance, patient, kind, canal, destino, opts)}
    end
  end

  defp gravar_e_enfileirar(clinic, attendance, patient, kind, canal, destino, opts) do
    message =
      Messaging.enqueue_message!(
        %{
          attendance_id: attendance.id,
          appointment_id: attendance.appointment_id,
          patient_id: patient.id,
          canal: canal,
          kind: kind,
          template: Templates.para(kind),
          vars: vars(clinic, attendance, patient),
          destino: destino,
          disparado_por_id: Keyword.get(opts, :disparado_por_id)
        },
        tenant: clinic.id,
        authorize?: false
      )

    Api.Messaging.SendJob.enqueue(message, agendar_para: quando_enviar(clinic))

    message
  end

  @doc """
  As variáveis do template (§4). O **nome da clínica sempre entra** — é o §9.1.4, não enfeite:
  a v1 vai com remetente único da Cinetra, e é a primeira linha da mensagem que diz de quem ela é.

  Data e hora saem no fuso da clínica (ADR-009). Guardá-las renderizadas é o que mantém o
  histórico verdadeiro: se a sessão for remarcada depois, a mensagem que saiu continua dizendo o
  horário que ela de fato anunciou.
  """
  def vars(clinic, attendance, patient) do
    {data, hora} = data_hora_local(attendance.session_starts_at, clinic.timezone)

    %{
      "clinica" => clinic.nome,
      "paciente" => patient.nome,
      "data" => data,
      "hora" => hora
    }
  end

  defp data_hora_local(nil, _tz), do: {"—", "—"}

  defp data_hora_local(instante, tz) do
    local = DateTime.shift_zone!(instante, tz)

    {Calendar.strftime(local, "%d/%m/%Y"), Calendar.strftime(local, "%H:%M")}
  end

  # Dois booleanos na ficha (D16/D19). `lgpd` é o termo de tratamento de dado — outro assunto,
  # e não governa envio; `comunicacao` é o que diz se podemos falar com a pessoa.
  defp consentiu?(%{comunicacao: true}), do: true
  defp consentiu?(_patient), do: false

  @doc """
  Quando esta mensagem pode sair: agora, ou no fim da janela de silêncio (§7).

  **Adia, não descarta.** Um lembrete gerado às 23h para uma sessão das 9h ainda é útil às 8h;
  jogá-lo fora seria perder a mensagem por causa do relógio. Devolve `nil` para "agora" — é o que
  o Oban entende como imediato.
  """
  def quando_enviar(clinic, agora \\ nil) do
    agora = agora || DateTime.utc_now()

    case silencio(clinic) do
      nil -> nil
      {inicio, fim} -> adiar_se_silenciado(agora, inicio, fim, clinic.timezone)
    end
  end

  defp silencio(%{msg_silencio_inicio: i, msg_silencio_fim: f})
       when is_integer(i) and is_integer(f) and i != f,
       do: {i, f}

  # Janela ausente — ou de largura zero (21h→21h), que não silencia nada e cujo tratamento
  # ingênuo silenciaria o dia inteiro.
  defp silencio(_clinic), do: nil

  defp adiar_se_silenciado(agora, inicio, fim, tz) do
    local = DateTime.shift_zone!(agora, tz)

    if dentro?(local.hour, inicio, fim) do
      local
      |> proximo_fim_da_janela(fim)
      |> DateTime.shift_zone!("Etc/UTC")
    end
  end

  # A janela cruza a meia-noite quando `inicio > fim` (o caso normal: 21h→8h). Escrever isto como
  # `hora >= inicio and hora < fim` silenciaria **nada** nesse caso — a comparação seria sempre
  # falsa —, e o defeito não apareceria em teste que só cobre janela dentro do mesmo dia.
  defp dentro?(hora, inicio, fim) when inicio > fim, do: hora >= inicio or hora < fim
  defp dentro?(hora, inicio, fim), do: hora >= inicio and hora < fim

  # Reconstrói o instante pelo **fuso**, e não por `%{local | hour: fim}`: trocar o campo à mão
  # mantém o `utc_offset` do horário anterior, e num país com horário de verão isso produz um
  # instante uma hora fora do que a tela diz. `DateTime.new/4` recalcula o offset da data-hora.
  defp proximo_fim_da_janela(local, fim) do
    hoje = montar(local, DateTime.to_date(local), fim)

    # Já passou das `fim` horas de hoje (estamos no ramo noturno da janela) → é a de amanhã.
    if DateTime.compare(hoje, local) == :gt,
      do: hoje,
      else: montar(local, Date.add(DateTime.to_date(local), 1), fim)
  end

  defp montar(local, data, hora) do
    {:ok, instante} = DateTime.new(data, Time.new!(hora, 0, 0), local.time_zone)
    instante
  end
end
