defmodule Api.RateLimiter do
  @moduledoc """
  Rate limiter da aplicação (Hammer 7, backend ETS, algoritmo **sliding window**).

  Janela deslizante (não fixa) para evitar o burst na virada de janela: conta os hits nos
  últimos `scale` milissegundos (a unidade do Hammer), não num balde alinhado ao relógio. Usado pelo
  `ApiWeb.Plugs.RateLimitAuth` nos endpoints de autenticação (auditoria doc 13, causa A).

  A enforcement é **ligada só em produção** (`config :api, rate_limit_enabled: true` no
  `prod.exs`); em dev/test a tabela ETS existe mas o plug não bloqueia — o processo aqui
  sobe em todos os ambientes de propósito, para o teste poder exercitá-lo.

  ## Por que o limite global NÃO mora aqui

  A janela deslizante custa caro por desenho: o Hammer grava **uma linha por requisição** e cada
  `hit/3` faz `:ets.select` com a chave no *guard*, não no *head* — ou seja, varre a tabela
  inteira. Com os três endpoints de auth isso é irrelevante (volume baixíssimo). Com o tráfego
  todo, vira o oposto do que um rate limiter existe para fazer. Medido no bate-volta (doc 68):

      tabela vazia      14,3 µs por hit
      100 mil linhas    31.110 µs por hit   (4× o custo de um request inteiro)
      1 milhão          472.229 µs por hit

  E a linha entra **mesmo quando a requisição é barrada** (`insert_new` roda antes da checagem),
  então N cresce com o tráfego *recebido*, não com o permitido: a enxurrada financia a própria
  amplificação. Por isso o limite global usa `Api.RateLimiter.Global`, com janela fixa, tabela
  própria e custo O(1) — e a tabela separada é o que impede o tráfego geral de degradar o
  anti-brute-force do magic link, que antes dividia esta aqui.
  """
  use Hammer, backend: :ets, algorithm: :sliding_window
end
