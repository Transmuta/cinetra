defmodule Api.Messaging.Dispatch do
  @moduledoc """
  **O único lugar que decide se uma mensagem sai, e por onde** (doc 52 §10.3).

  Espalhar essa decisão por gatilho é como se manda mensagem para quem pediu para parar: são
  quatro perguntas, na ordem, e basta um caminho esquecer uma delas.

      consentimento na ficha? → tem destino? → pediu para parar? → qual canal?

  Depois de "sim, dá para falar com esta pessoa" vem uma segunda camada, de natureza diferente:
  **já falamos?** São as travas de repetição de `barreira/3` — já respondeu, já tem uma na fila,
  já bateu o teto. As quatro primeiras perguntam se **pode**; estas perguntam se **deve**.

  Toda a razão de este módulo existir é ser chamado pelos **dois** lados:

    * o envio (o clique da recepção, os gatilhos de remarcação/cancelamento, o cron do lembrete) —
      que precisa saber se manda;
    * a **leitura** da timeline — que precisa explicar por que *não* mandou (§6). O "nada
      enviado" da tela não é uma linha em `Message`; é a ausência dela, e quem a explica é
      `avaliar/2`.

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

  ## Canal desligado não é "paciente sem contato"

  `Api.Messaging.Transport.disponivel?/1` responde por canal, e com WhatsApp desligado a
  resolução cai para o e-mail pelo caminho normal. Mas **quando não há reserva** os dois casos
  se separam: sem destino na ficha é `:sem_contato`, e destino sem transporte é
  `:canal_indisponivel`. São ações diferentes de gente diferente — preencher a ficha é da
  recepção, ligar o canal não é.
  """
  require Logger

  import Api.Tenancy, only: [in_clinic: 2]

  # Os tipos em que uma segunda mensagem **não diz nada de novo** — ver `barreira/3`. Remarcação e
  # cancelamento ficam fora: cada um anuncia um FATO novo, e remarcar duas vezes precisa avisar
  # duas vezes.
  @com_barreira [:confirmacao, :lembrete]

  # Quantas confirmações uma presença pode receber, no total.
  #
  # **Dois, e o número tem uma leitura:** o primeiro clique da recepção e a insistência legítima de
  # quem não obteve resposta. O terceiro é o paciente sendo cobrado três vezes pela mesma sessão —
  # no WhatsApp, três vezes **pago**, e é assim que se perde um número por bloqueio (§9.1.1).
  #
  # Os dois eram "a automática da criação + um clique" até 2026-07-31 (doc 98), quando a criação
  # deixou de falar com o paciente. O teto não mudou de número porque o que ele protege é o
  # paciente, não a origem do disparo.
  @limite_de_confirmacoes 2

  # Os estados que **gastam** uma unidade do teto: a mensagem chegou ao paciente, ou vai chegar.
  #
  # `:falhou` e `:descartada` de fora, e não por generosidade: nenhuma das duas falou com ninguém.
  # Contá-las travaria exatamente quem mais precisa reenviar — a recepção que acabou de corrigir o
  # e-mail errado na ficha depois de dois bounces.
  @alcancam_o_paciente [:pendente, :enviado, :entregue, :lido]

  alias Api.Messaging
  alias Api.Messaging.Templates
  alias Api.Messaging.Transport

  @typedoc """
  Por que uma mensagem não sai. São os textos do §6, e a fronteira os traduz para a tela:

    * `:sem_consentimento` — a ficha não autoriza comunicação;
    * `:sem_contato` — não há e-mail nem telefone utilizável **na ficha**;
    * `:canal_indisponivel` — a ficha tem destino, mas o transporte dele não está de pé;
    * `:opt_out` — o paciente pediu para parar;
    * `:ja_na_fila` — já existe uma mensagem deste tipo esperando para esta presença;
    * `:ja_confirmou` — o paciente já respondeu que vem;
    * `:limite_de_envios` — a presença já recebeu o teto de confirmações.

  Os **três últimos** não vêm de `avaliar/2`: nenhum é sobre poder falar com a pessoa, e todos são
  sobre não falar **de novo**. Por isso são decididos em `dispatch/5` (ver `barreira/3`), depois de
  a resposta já ser "sim, dá para enviar".

  Os dois do meio já foram um átomo só, e a fusão produzia uma mentira no balcão: paciente com
  celular na ficha e WhatsApp desligado lia "sem e-mail nem telefone cadastrado". Cada motivo
  existe porque leva a uma **ação diferente** — e "abra a ficha e preencha" é o conselho errado
  para quem já preencheu. `:canal_indisponivel` não é da recepção: é de quem opera a instalação.
  """
  @type motivo ::
          :sem_consentimento
          | :sem_contato
          | :canal_indisponivel
          | :opt_out
          | :ja_na_fila
          | :ja_confirmou
          | :limite_de_envios

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
  #
  # São duas perguntas, e separá-las é o que dá a explicação certa para cada silêncio: primeiro
  # "a ficha tem destino?", depois "esse destino tem transporte?". Uma pergunta só respondia
  # "sem contato" para as duas — ver o `@typedoc` de `motivo`.
  defp escolher_canal(patient, clinic_id) do
    case destinos(patient) do
      [] -> {:skip, :sem_contato}
      destinos -> por_transporte_disponivel(destinos, clinic_id)
    end
  end

  defp por_transporte_disponivel(destinos, clinic_id) do
    case Enum.filter(destinos, fn {canal, _destino} -> Transport.disponivel?(canal) end) do
      [] ->
        {:skip, :canal_indisponivel}

      [{canal, destino} | resto] ->
        _ = resto

        if Messaging.opted_out?(canal, destino, clinic_id) do
          # Aqui está o §10.4. Não é "tenta o `resto`": quem pediu para parar pediu para parar,
          # e a reserva não pode virar contorno.
          {:skip, :opt_out}
        else
          {:ok, canal, destino}
        end
    end
  end

  @doc """
  Os destinos que existem **na ficha**, em ordem de preferência (C8) — sem opinar sobre
  transporte. "Telefone fixo" e "campo vazio" caem aqui, porque os dois são ausência de destino;
  "o WhatsApp está desligado" não, porque aquilo não é um dado da ficha.

  Público porque o opt-in (`Api.Messaging.revoke_patient_opt_outs/2`) precisa da MESMA derivação,
  já canonicalizada: revogar por um número escrito de outro jeito não encontra a linha gravada.
  Duplicar isso lá criaria a segunda definição de "por onde eu falo com este paciente".
  """
  def destinos(patient) do
    [{:whatsapp, whatsapp_de(patient)}, {:email, normalizar(:email, patient.email)}]
    |> Enum.filter(fn {_canal, destino} -> destino != nil end)
  end

  # **Fixo não é canal de WhatsApp.** O telefone virou obrigatório na ficha (§9), e obrigar sem
  # aceitar fixo empurraria a recepção a digitar um celular qualquer para conseguir salvar — o
  # dado ficaria pior para a regra ficar bonita. Então o fixo entra na ficha e simplesmente não
  # é destino aqui: cai para o e-mail pelo caminho normal, e sem e-mail a timeline mostra
  # `:sem_contato` — que é a verdade, porque não há para onde mandar.
  defp whatsapp_de(patient) do
    numero = normalizar(:whatsapp, patient.tel)

    if numero && celular?(numero), do: numero
  end

  @doc """
  Este número E.164 é um celular brasileiro?

  Regra do plano de numeração: celular é DDD + **nove** dígitos começando por 9; fixo tem oito. É
  a única heurística disponível sem consultar a API — e consultar custaria uma chamada de rede por
  paciente, por mensagem, para responder algo que o formato já diz.

      iex> Api.Messaging.Dispatch.celular?("+5511987654321")
      true

      iex> Api.Messaging.Dispatch.celular?("+551133334444")
      false
  """
  def celular?("+55" <> nacional) when byte_size(nacional) == 11,
    do: String.at(nacional, 2) == "9"

  def celular?(_numero), do: false

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
    digitos = Api.Texto.somente_digitos(valor)

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
  chama são os gatilhos do ciclo de vida do bloco e o cron do lembrete, e nenhum deles pode falhar
  porque um paciente não tem e-mail.

  Recebe a `attendance` já com `patient` e `appointment` carregados, e a `clinic` — quem chama
  costuma ter as três à mão, e lê-las aqui de novo seria N+1 no caminho do cron.

  `opts[:vars_extras]` acrescenta variáveis ao template. É o que a massa por pacote usa para
  dizer *quantas* sessões e *qual* pacote — dado que não existe numa mensagem de sessão única e
  que não cabe em `vars/3`, que só conhece clínica, paciente e horário.
  """
  @spec dispatch(map(), map(), map(), atom(), keyword()) :: {:ok, map()} | {:skip, motivo()}
  def dispatch(clinic, attendance, patient, kind, opts \\ []) do
    with {:ok, canal, destino} <- avaliar(patient, clinic_id: clinic.id),
         nil <- barreira(clinic, attendance, kind) do
      {:ok, gravar_e_enfileirar(clinic, attendance, patient, kind, canal, destino, opts)}
    else
      {:skip, motivo} -> {:skip, motivo}
      # `barreira/3` devolve o átomo do motivo, ou `nil` para "pode mandar" — e `nil` não chega
      # aqui, porque é ele que faz o `with` seguir.
      motivo when is_atom(motivo) -> {:skip, motivo}
    end
  end

  # As travas de repetição (§4), avaliadas depois de "dá para falar com esta pessoa?". Devolve o
  # motivo, ou `nil` quando nada barra.
  #
  # **Uma leitura só para os três predicados.** Eles olham recortes diferentes do mesmo punhado de
  # linhas (1–4 por presença), e uma query por pergunta seriam três idas ao banco em todo envio.
  #
  # **Roda dentro de `in_clinic/2`, e isso não é zelo.** O `dispatch/5` é chamado FORA de qualquer
  # transação com GUC (o controller sai do `in_clinic` antes de mapear os participantes; o cron
  # nunca entrou), e a escrita só funciona porque a própria ação carrega o `SetTenantGuc`. Uma
  # leitura solta aqui rodaria sem GUC, a RLS devolveria lista vazia, e as travas passariam a nunca
  # travar — em silêncio, e com a suíte verde, porque no `mix test` o sandbox roda como superusuário
  # (é a lição de `.claude/rules` / doc 30 que já custou três medições erradas).
  defp barreira(clinic, attendance, kind) when kind in @com_barreira do
    in_clinic(clinic.id, fn ->
      attendance.id
      |> Messaging.list_attendance_messages!(authorize?: false)
      |> primeira_trava(kind)
    end)
  end

  defp barreira(_clinic, _attendance, _kind), do: nil

  # O lembrete tem **só** a trava da fila: ele é do cron, um por sessão, e o teto de confirmação
  # não é dele. Um controle que calasse os dois faria uma coisa com o nome de outra.
  defp primeira_trava(mensagens, :lembrete) do
    if na_fila?(mensagens, :lembrete), do: :ja_na_fila
  end

  # A ordem das três é a do que informa melhor quem lê o resultado no balcão: "ele já respondeu"
  # encerra o assunto, "a anterior ainda está na fila" é temporário e volta a permitir, e o teto é
  # definitivo para esta sessão.
  defp primeira_trava(mensagens, :confirmacao) do
    cond do
      ja_confirmou?(mensagens) -> :ja_confirmou
      na_fila?(mensagens, :confirmacao) -> :ja_na_fila
      alcancadas(mensagens, :confirmacao) >= @limite_de_confirmacoes -> :limite_de_envios
      true -> nil
    end
  end

  # **Qualquer tipo conta, não só a confirmação.** `SendJob.render/1` põe o link de resposta em toda
  # mensagem, então o paciente pode responder "vou" ao lembrete — e quem já disse que vem não deve
  # receber um pedido de confirmação.
  #
  # `:quer_remarcar` **não** barra, e a assimetria é o ponto: aquilo é o oposto de "está resolvido".
  # A recepção liga, acerta o horário, e a confirmação nova é justamente o que fecha o assunto.
  defp ja_confirmou?(mensagens), do: Enum.any?(mensagens, &(&1.resposta == :confirmou))

  # Uma deste tipo **ainda na fila** significa que o envio já foi pedido e não saiu: enfileirar
  # outra não adianta o relógio, só duplica o que vai chegar. Dentro da janela de silêncio (§7),
  # onde a primeira fica horas parada, é o caso comum — quem clica não vê nada acontecer e clica
  # de novo. Medido no dev de 2026-07-28: quatro linhas idênticas para o mesmo paciente.
  defp na_fila?(mensagens, kind),
    do: Enum.any?(mensagens, &(&1.kind == kind and &1.status == :pendente))

  defp alcancadas(mensagens, kind),
    do: Enum.count(mensagens, &(&1.kind == kind and &1.status in @alcancam_o_paciente))

  defp gravar_e_enfileirar(clinic, attendance, patient, kind, canal, destino, opts) do
    # Uma leitura só do relógio para os dois usos. Chamar `quando_enviar/1` duas vezes deixaria a
    # linha e o job discordarem quando a chamada cai na virada da janela — a tela diria uma hora e
    # o Oban outra.
    agendado_para = quando_sai(kind, clinic)

    # A corrida da barreira (doc 96, B-8), fechada no banco.
    #
    # `barreira/3` lê numa transação e esta escrita acontece em **outra**: dois pedidos simultâneos
    # para a mesma `(attendance_id, kind)` passam os dois pela leitura. A barreira resolve o caso
    # sequencial; quem arbitra concorrência é o Postgres, pelo índice único parcial
    # `messages_uma_pendente_por_presenca`. No WhatsApp cada duplicata é **paga**.
    #
    # Aqui a violação é traduzida de volta para a linguagem do domínio: se o banco diz "já existe
    # uma pendente para esta presença e este tipo", isso é exatamente `{:skip, :ja_na_fila}` — a
    # mesma resposta que a barreira daria se tivesse enxergado a linha a tempo.
    attrs = %{
      attendance_id: attendance.id,
      appointment_id: attendance.appointment_id,
      patient_id: patient.id,
      canal: canal,
      kind: kind,
      template: Templates.para(kind),
      vars: Map.merge(vars(clinic, attendance, patient), extras(opts)),
      destino: destino,
      disparado_por_id: Keyword.get(opts, :disparado_por_id),
      agendado_para: agendado_para
    }

    attrs
    |> Messaging.enqueue_message!(tenant: clinic.id, authorize?: false)
    |> enfileirar(clinic, agendado_para)
  rescue
    erro ->
      # SÓ esta constraint, pelo nome. Engolir qualquer erro aqui esconderia defeito de validação
      # como se fosse concorrência — trocaria um bug caro por um silêncio, que é pior.
      if colisao_de_pendente?(erro), do: {:skip, :ja_na_fila}, else: reraise(erro, __STACKTRACE__)
  end

  # A violação chega como `Postgrex.Error` (o índice é escrito à mão, fora do conhecimento do Ash)
  # ou embrulhada num erro do Ash. Casar pelo nome do índice cobre as duas formas sem depender de
  # qual camada traduziu.
  defp colisao_de_pendente?(erro) do
    inspect(erro) =~ "messages_uma_pendente_por_presenca"
  end

  # O retorno do `Oban.insert` NÃO pode ser descartado. Sem job, a linha fica `:pendente` para
  # sempre — e aí `na_fila?/2` passa a recusar toda tentativa futura com `{:skip, :ja_na_fila}`.
  # Não havia caminho de volta: nem cron, nem botão de reenviar; a tela dizia "Na fila"
  # indefinidamente e a mensagem nunca saía (doc 96, B-4).
  #
  # Marcar `:falhou` é o que devolve o controle à recepção: o motivo aparece na tela e o próximo
  # disparo é aceito, porque a barreira só bloqueia o que está pendente.
  defp enfileirar(message, clinic, agendado_para) do
    case Api.Messaging.SendJob.enqueue(message, agendar_para: agendado_para) do
      {:ok, _job} ->
        message

      {:error, motivo} ->
        Logger.error("não foi possível enfileirar o envio; a mensagem vai para :falhou",
          message_id: message.id,
          clinic_id: clinic.id,
          motivo: inspect(motivo)
        )

        marcar_falha_de_enfileiramento(message, clinic.id)
    end
  end

  defp marcar_falha_de_enfileiramento(message, clinic_id) do
    Messaging.do_advance_message!(
      message,
      %{novo_status: :falhou, erro: "nao_enfileirada"},
      tenant: clinic_id,
      authorize?: false
    )
  rescue
    # Se nem o registro da falha passa, devolver a linha original é melhor que derrubar o
    # disparo inteiro: o efeito visível continua sendo "não saiu", que é a verdade.
    _ -> message
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
    |> com_conta_de_whatsapp(clinic)
  end

  # O número pelo qual esta clínica fala viaja **na mensagem**, não é lido no transporte.
  #
  # Duas razões, e a segunda é a que decide. A primeira: o `SendJob` sai da transação com GUC
  # antes de entregar (para não segurar conexão pelo tempo da rede alheia), então uma leitura de
  # `Clinic` lá dentro rodaria sem GUC e a RLS devolveria vazio — calado. A segunda: o número é
  # parte do **histórico**. "Mandamos deste número" precisa continuar verdadeiro depois que a
  # clínica migrar para número próprio (§9.1.4), pela mesma razão que `destino` é congelado.
  defp com_conta_de_whatsapp(vars, %{zernio_account_id: id}) when is_binary(id) and id != "",
    do: Map.put(vars, "zernio_account_id", id)

  defp com_conta_de_whatsapp(vars, _clinic), do: vars

  # Chaves string, como o resto de `vars` — a coluna é `:map` e volta do banco com chave string.
  # Um `%{quantas: ...}` de átomo entraria no jsonb e sairia como `"quantas"` na leitura, e o
  # template renderizaria `"—"` sem erro nenhum.
  defp extras(opts) do
    opts
    |> Keyword.get(:vars_extras, %{})
    |> Map.new(fn {chave, valor} -> {to_string(chave), valor} end)
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

  # O lembrete **ignora a janela de silêncio**; todo o resto a respeita (decisão de 2026-07-31,
  # doc 98).
  #
  # A exceção é aritmética, não preferência. Adiar serve a uma mensagem que continua verdadeira
  # horas depois — a confirmação de uma sessão da semana que vem é. O lembrete, desde que passou a
  # sair **2 h** antes (`Clinic.msg_lembrete_horas`), não é: com a janela padrão 21h→8h, o lembrete
  # de uma sessão das 7h30 é gerado às 5h30, adiado para as 8h e entregue **meia hora depois** de a
  # sessão começar — anunciando como futuro algo que já passou. Adiar aqui não protege o sono de
  # ninguém; só produz uma mensagem errada.
  #
  # O outro lado da escolha, registrado para não ser redescoberto como bug: uma sessão bem cedo faz
  # o lembrete sair dentro da madrugada. É aceito porque a mensagem é sobre algo que o paciente
  # está prestes a fazer — quem tem sessão às 7h30 já está de pé às 5h30 —, e porque o alternativo
  # (descartar) cala justamente o aviso mais útil do dia.
  defp quando_sai(:lembrete, _clinic), do: nil
  defp quando_sai(_kind, clinic), do: quando_enviar(clinic)

  @doc """
  Quando esta mensagem pode sair: agora, ou no fim da janela de silêncio (§7).

  **Adia, não descarta.** Uma confirmação gerada às 23h para uma sessão de sexta ainda é útil às
  8h; jogá-la fora seria perder a mensagem por causa do relógio. Devolve `nil` para "agora" — é o
  que o Oban entende como imediato.

  Vale para todo tipo **menos o lembrete**, que sai na hora — ver `quando_sai/2`.
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
