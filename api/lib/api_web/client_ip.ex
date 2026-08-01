defmodule ApiWeb.ClientIp do
  @moduledoc """
  IP real do cliente para chaves de rate limit — a decisão de **qual header de proxy merece
  confiança**. Extraído do `RateLimitAuth` quando o limite global chegou: os dois plugs precisam
  da mesma resolução, e uma segunda cópia divergiria calada.

  A conexão TCP na API é sempre de um proxy (o BFF, na rede interna; ou a edge, no tráfego
  público), nunca do browser — então `remote_ip` sozinho é o do proxy. Ordem de confiança:

    1. os **headers confiáveis** configurados, na ordem em que vierem;
    2. `x-forwarded-for` — setado pelo BFF no tráfego INTERNO (inalcançável de fora), então
       confiável nesse hop;
    3. `remote_ip` — fallback (dev/local sem proxy).

  ## Por que a lista é configurável, e não constante

  Um header só é confiável se **a topologia garante que alguém o sobrescreve**. Numa edge que
  escreve o header por cima de qualquer valor do cliente (era o caso do `fly-client-ip` na Fly),
  ele é autoritativo e à prova de spoof. Sob um proxy que não o conhece — o Traefik do Dokploy,
  hoje — ninguém escreve nem remove esse header, e mantê-lo na cadeia entregaria a chave do rate
  limit para o próprio cliente escrever, transformando os dois limitadores em no-op sem que nada
  quebre visivelmente (bate-volta doc 68, causa B).

  Isto é, portanto, **configuração de deploy**, não constante de código:

      config :api, trusted_client_ip_headers: ["cf-connecting-ip"]

  **O default é a lista vazia**: nenhum header de vendor é confiável até que o deploy declare que
  a edge o sobrescreve. Cai-se então no `x-forwarded-for`, que é o que a topologia atual de fato
  garante. O default já foi `["fly-client-ip"]` e sobreviveu à saída da Fly — como nenhum ambiente
  sobrescrevia a lista, o header virou forjável em produção. Ao entrar numa edge nova, adicione o
  header dela aqui **junto** com a troca do proxy: é a mesma decisão, e separá-las é como o limite
  vira decorativo.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @default_trusted []

  @doc """
  O IP do cliente, como string. Nunca falha: sem header confiável e sem `x-forwarded-for`, devolve
  o peer da conexão.
  """
  @spec get(Plug.Conn.t()) :: String.t()
  def get(conn) do
    trusted = Application.get_env(:api, :trusted_client_ip_headers, @default_trusted)

    Enum.find_value(trusted ++ ["x-forwarded-for"], &forwarded(conn, &1)) || peer_ip(conn)
  end

  # **Contado a partir do fim**, não do começo (doc 96, L-4; relacionado ao débito D-16).
  #
  # O `x-forwarded-for` é uma lista que cada salto **acrescenta**, escrevendo o IP de quem falou
  # com ele. Logo, num `A, B, C`: `A` é o que o CLIENTE mandou (e portanto o que um atacante
  # escolhe), e `C` é o que o último proxy observou. Ler `List.first/1` — o que este módulo fazia —
  # entregava a chave de rate limit ao atacante: bastava rotacionar o header a cada request para
  # nunca estourar o teto, inclusive no limitador anti-brute-force do magic link.
  #
  # Isso mordia **no default do deploy**: `TRUSTED_CLIENT_IP_HEADER` vem vazio no
  # `compose.dokploy.yml`, e o Traefik anexa em vez de substituir.
  #
  # Quantos elementos descartar depende de **quantos proxies confiáveis** estão na frente, e não
  # há como adivinhar: com 1 salto o cliente é o último item; com 2, o penúltimo. Por isso o
  # número é configuração explícita, com default 1 — a topologia atual (Traefik sozinho). Ao
  # colocar uma edge na frente, este número sobe **junto** com a troca do proxy, como o header
  # confiável logo acima.
  @default_hops 1

  defp forwarded(conn, header) do
    case get_req_header(conn, header) do
      [value | _] -> value |> String.split(",") |> cliente() |> nil_if_empty()
      [] -> nil
    end
  end

  defp cliente(itens) do
    hops = Application.get_env(:api, :trusted_proxy_hops, @default_hops)

    itens
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ""
      lista -> Enum.at(lista, max(length(lista) - hops, 0))
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  defp peer_ip(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()
end
