ExUnit.start()

# O storage da suíte (`config/test.exs` aponta o adaptador para cá). Iniciado uma vez, antes de
# qualquer teste: os anexos precisam de um lugar para pôr bytes que não seja o Cloudflare.
{:ok, _} = Api.Storage.Memory.start_link()
