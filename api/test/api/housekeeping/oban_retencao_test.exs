defmodule Api.Housekeeping.ObanRetencaoTest do
  @moduledoc """
  A tabela `oban_jobs` também precisa encolher (bate-volta da Onda 4).

  O projeto já tinha duas podas — trilha e caixa de notificações — e nenhuma para a fila que
  **executa** as duas. Medido no dev antes do conserto: 779 jobs `completed` acumulados em 4
  dias, nada os apagando. A Onda 4 piorou o quadro de propósito: os crons novos garantem 314
  linhas por dia (288 do `SessionSoonJob` a cada 5 min + 24 do resumo + 2 das podas), **antes**
  de qualquer job disparado por evento.

  O teste é de configuração e não de comportamento porque o que se perdeu foi exatamente isso: o
  `Oban.Plugins.Pruner` não estava na lista. Um teste de comportamento aqui exigiria subir o
  plugin e adiantar o relógio, e guardaria menos do que esta linha.
  """
  use ExUnit.Case, async: true

  test "o Oban poda os próprios jobs concluídos" do
    plugins = Application.get_env(:api, Oban)[:plugins]

    pruner =
      Enum.find_value(plugins, fn
        {Oban.Plugins.Pruner, opts} -> opts
        _ -> nil
      end)

    assert pruner, "sem Oban.Plugins.Pruner: a tabela oban_jobs cresce para sempre"

    # A janela é decisão humana, como as das podas (ver `Api.Housekeeping.PruneNotifications`):
    # curta demais e some o rastro de "por que o lembrete não saiu na terça".
    assert pruner[:max_age] >= 24 * 60 * 60
  end
end
