defmodule Api.RateLimiter.Global do
  @moduledoc """
  Limitador do tráfego geral (Hammer 7, backend ETS, algoritmo **janela fixa**) — tabela própria,
  separada do `Api.RateLimiter` dos endpoints de auth.

  ## Por que janela fixa aqui, e deslizante lá

  A janela fixa guarda **uma linha por chave** e resolve cada `hit/3` com um `:ets.update_counter`
  na chave completa: O(1), sem varredura. A deslizante guarda uma linha por *requisição* e varre a
  tabela a cada chamada. Medido no bate-volta (doc 68), com 100 mil chaves:

      deslizante   31.110 µs por hit
      fixa              0,39 µs por hit

  O preço da janela fixa é o burst na virada: no pior caso passam 2× o limite em torno da fronteira
  (400 requisições em um instante, entre o fim de um minuto e o começo do outro). Para um teto
  grosso de proteção de infraestrutura isso é irrelevante — o que se quer é cortar enxurrada, não
  contar com precisão. Onde a precisão importa (5 magic links por e-mail em 15 minutos, que é
  regra de segurança e não de capacidade), a janela deslizante continua valendo: é o
  `Api.RateLimiter`.

  ## A tabela é separada de propósito

  Enquanto os dois limitadores dividiam uma tabela, uma enxurrada anônima degradava o
  anti-brute-force do magic link junto — o login caía como efeito colateral de um ataque que não
  era contra ele.
  """
  use Hammer, backend: :ets, algorithm: :fix_window
end
