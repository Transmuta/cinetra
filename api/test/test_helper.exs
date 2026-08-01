# `:compose` fica de fora por padrão porque o `docker-compose.yml` monta só `api/` em `/app`: de
# dentro do container os arquivos da raiz não existem, e o teste falharia por ausência de arquivo
# — que não é o defeito que ele procura. No CI o checkout traz o repositório inteiro, e é lá que
# ele vale; o job da API roda `mix coveralls --include compose`.
ExUnit.start(exclude: [:compose])

# O storage da suíte (`config/test.exs` aponta o adaptador para cá). Iniciado uma vez, antes de
# qualquer teste: os anexos precisam de um lugar para pôr bytes que não seja o Cloudflare.
{:ok, _} = Api.Storage.Memory.start_link()

# O transporte de WhatsApp da suíte (doc 65). Mesma ideia: um lugar para a mensagem ir que não
# seja a Zernio. O canal nasce desligado em `config/test.exs`; quem o liga é o teste.
{:ok, _} = Api.Messaging.WhatsAppMemory.start_link()
