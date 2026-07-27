defmodule Api.Records.AttachmentEventAction do
  @moduledoc """
  O que aconteceu com o anexo. `:visualizou` é o que a LGPD cobra e o que nenhuma trilha de
  escrita registra — é gravado quando a **URL assinada é emitida**, o instante em que o acesso é
  efetivamente concedido.
  """
  use Ash.Type.Enum, values: [:enviou, :visualizou, :renomeou, :removeu]
end
