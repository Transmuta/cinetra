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

  Um header só é confiável se **a topologia garante que alguém o sobrescreve**. Na Fly,
  `fly-client-ip` é escrito pela edge por cima de qualquer valor do cliente: autoritativo e à
  prova de spoof. Sob outro proxy — Traefik, por exemplo — ninguém escreve nem remove esse header,
  e mantê-lo no topo da cadeia entregaria a chave do rate limit para o próprio cliente escrever,
  transformando os dois limitadores em no-op sem que nada quebre visivelmente (bate-volta doc 68,
  causa B).

  Isto é, portanto, **configuração de deploy**, não constante de código:

      config :api, trusted_client_ip_headers: ["x-forwarded-for"]

  O default preserva a topologia atual (Fly). Ao trocar de edge, ajuste a lista **junto** com a
  troca do proxy — é a mesma decisão, e separá-las é como o limite vira decorativo.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @default_trusted ["fly-client-ip"]

  @doc """
  O IP do cliente, como string. Nunca falha: sem header confiável e sem `x-forwarded-for`, devolve
  o peer da conexão.
  """
  @spec get(Plug.Conn.t()) :: String.t()
  def get(conn) do
    trusted = Application.get_env(:api, :trusted_client_ip_headers, @default_trusted)

    Enum.find_value(trusted ++ ["x-forwarded-for"], &forwarded(conn, &1)) || peer_ip(conn)
  end

  defp forwarded(conn, header) do
    case get_req_header(conn, header) do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim() |> nil_if_empty()
      [] -> nil
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  defp peer_ip(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()
end
