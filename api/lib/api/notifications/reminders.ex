defmodule Api.Notifications.Reminders do
  @moduledoc """
  Os lembretes **por relógio** (#51, doc 31 §3d) — a classe que não nasce de uma ação de
  ninguém: "você tem N atendimentos amanhã" e "sua próxima sessão começa às HH:MM".

  Aqui mora o que os dois têm em comum, que é justamente a parte que dá errado quando cada job
  resolve por si.

  ## 1. "19h" e "daqui a 15 minutos" são perguntas de fuso, não de UTC

  Cada clínica tem o seu fuso (ADR-009). Um cron às 22:00 UTC é 19h em São Paulo e outra hora em
  qualquer outra clínica. Por isso o resumo roda **de hora em hora** e cada clínica só é servida
  quando o relógio **dela** marca a hora configurada.

  ## 2. A varredura é por clínica, sob a GUC

  As tabelas têm RLS (ADR-018) e o job roda como `cinetra_app`. Um `SELECT` cross-tenant não
  volta vazio por acaso: volta vazio **sempre**, e passa no `mix test`, onde o sandbox conecta
  como superusuário. Mesmo motivo do `Api.Housekeeping.Poda`, de onde vem o `clinicas/0` — a
  lista de clínicas não é assunto de poda, e esse empréstimo de namespace está anotado como
  dívida no bate-volta da Onda 4 (doc 44 §5).

  ## 3. Quem recebe é o dono da coluna

  Lembrete é sobre a agenda de alguém, então o destinatário é o usuário vinculado ao
  `professional_id` do bloco. Profissional sem usuário (o caso comum da clínica pequena) não
  gera nada — e a pergunta "existe algum?" é a **barata**, feita antes de ler a agenda, pelo
  mesmo motivo que o `Fanout.participant_missed/2` documenta.
  """
  import Ash.Expr

  alias Api.Notifications.Fanout
  alias Api.Scheduling
  alias Api.Scheduling.LocalTime

  # Lembrar de sessão cancelada é pior que não lembrar. A lista de "bloco aberto" vem do módulo
  # que define os status — escrevê-la aqui de novo criaria a segunda fonte da verdade que o
  # bate-volta da Onda 4 pegou.
  @abertos Api.Scheduling.AppointmentStatus.abertos()

  @doc """
  Roda `fun.(clinic_id, tz)` para cada clínica cuja **hora local** é `hora`.

  `forcar?: true` ignora o relógio — é o que o teste e uma execução manual usam.
  """
  def em_cada_clinica_as(hora, opts \\ [], fun) when is_integer(hora) and is_function(fun, 2) do
    forcar? = Keyword.get(opts, :forcar?, false)

    Enum.reduce(Api.Housekeeping.Poda.clinicas(), 0, fn clinic_id, total ->
      tz = Scheduling.clinic_timezone(clinic_id)

      if forcar? or hora_local(tz) == hora do
        total + fun.(clinic_id, tz)
      else
        total
      end
    end)
  end

  @doc """
  Blocos vivos que **começam** na janela `[de, ate)`, agrupados por `professional_id`.

  O `COMEÇAM` é o detalhe que um teste de ladrilho pegou e a leitura ingênua erra: a ação
  `:in_range` filtra por **sobreposição** (`starts_at < to and ends_at > from`), porque foi feita
  para desenhar a grade — um bloco que atravessa a borda pertence ao dia. Para lembrete, isso é
  errado nas duas pontas:

    * uma sessão de 50 min **sobrepõe** três janelas de 5 min seguidas, e o profissional receberia
      o mesmo "sessão começando" três vezes;
    * uma sessão que começa 23:30 e termina 00:20 entraria na conta de **dois** dias no resumo.

  Por isso o recorte por `starts_at` vai junto na query. A janela da ação continua sendo a mesma
  (é ela que fecha a varredura por baixo, via `WindowLowerBound`) — o que se acrescenta é a
  pergunta certa.
  """
  def blocos_por_profissional(clinic_id, %DateTime{} = de, %DateTime{} = ate) do
    Api.Repo.with_clinic(clinic_id, fn ->
      Scheduling.list_appointments!(de, ate,
        tenant: clinic_id,
        authorize?: false,
        query: [filter: expr(status in ^@abertos and starts_at >= ^de and starts_at < ^ate)]
      )
    end)
    |> case do
      {:ok, appointments} -> Enum.group_by(appointments, & &1.professional_id)
      _ -> %{}
    end
  end

  @doc """
  Para cada coluna **com dono**, chama `fun.(user_id, blocos)` com os blocos que começam na
  janela. Devolve quantos avisos saíram.

  **A ordem das duas leituras é o ponto desta função existir**, e é o conserto do bate-volta da
  Onda 4. A pergunta barata — "existe algum profissional vinculado a um usuário nesta clínica?",
  1 query em `memberships` — vem **antes** da cara, que é varrer a agenda. Numa clínica sem esse
  vínculo (o caso comum da clínica pequena) não há a quem avisar, e ler a agenda é trabalho
  jogado fora **a cada rodada do cron, para sempre**. Medido no dev antes do conserto: 21 de 23
  clínicas sem ninguém a avisar, todas com a agenda lida a cada 5 minutos.

  É a mesma classe do CR-7 da Onda 3 (doc 43), e a lição que ela deixou está aplicada aqui de
  forma **estrutural**: a janela entra como argumento e as duas leituras acontecem nesta função,
  então não há como um chamador novo inverter a ordem. Antes, quem lia a agenda era o job, e
  esta função só recebia o resultado — a ordem certa dependia de cada chamador lembrar.
  """
  def por_dono_da_coluna(clinic_id, %DateTime{} = de, %DateTime{} = ate, fun)
      when is_function(fun, 2) do
    case Fanout.professional_users(clinic_id) do
      donos when map_size(donos) == 0 ->
        0

      donos ->
        clinic_id
        |> blocos_por_profissional(de, ate)
        |> Enum.reduce(0, fn {professional_id, blocos}, total ->
          case Map.get(donos, professional_id) do
            nil -> total
            user_id -> total + fun.(user_id, blocos)
          end
        end)
    end
  end

  @doc "O início do dia local `data`, em UTC."
  def inicio_do_dia(%Date{} = data, tz) do
    {:ok, dt} = LocalTime.to_utc(data, "00:00", tz)
    dt
  end

  @doc "A hora local (0..23) de agora, no fuso dado."
  def hora_local(tz) do
    DateTime.utc_now() |> DateTime.shift_zone!(tz) |> Map.fetch!(:hour)
  end
end
