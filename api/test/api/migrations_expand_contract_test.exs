defmodule Api.MigrationsExpandContractTest do
  @moduledoc """
  R-M22 (doc 95, onda 3 do doc 102): a regra de expand-contract era boa, estava escrita, e não
  tinha **nenhuma** automação.

  ## O que a regra diz, e por que ela é obrigatória aqui

  [`doc 59 §8`](../../../docs/59-deploy-dokploy-oci.md): *"nunca faça uma mudança de schema que
  quebre a versão do app que está rodando agora"*. Não é preferência de estilo — é consequência
  direta de como este deploy funciona. `compose.dokploy.yml` recria os containers em ordem de
  dependência, então **enquanto o `migrate` roda, o container ANTERIOR da API ainda serve
  tráfego** contra o schema já migrado.

  Uma coluna removida na fase errada produz erro em toda query que a mencione, durante a janela
  inteira do deploy — e agora há usuário dentro dessa janela.

  Que migrations destrutivas são escritas aqui está provado no próprio repositório: quatro delas
  removem coluna no `up` (a lista `@anteriores_ao_gate` abaixo).

  ## O que este gate faz — e o que ele explicitamente NÃO faz

  Ele exige que uma migration nova com operação destrutiva no `up` **declare** que a decisão foi
  tomada, com a marca `# expand-contract:` e uma justificativa na mesma linha.

  Ele **não prova que a mudança é segura**. Não tem como: saber se a coluna ainda é lida pela
  versão em execução é semântico, e depende de código que não está na migration. O máximo
  automatizável é a diferença entre *decisão explícita* e *distração* — e é essa a diferença que
  custou os incidentes que o doc 59 §10 lista como risco #4.

  ## Por que só o `up`

  `remove/1` dentro do `down` é o rollback de um `add` e é **normal**. Medido: das 84 migrations,
  20 têm operação destrutiva em algum lugar e apenas **4** a têm no `up`. Um gate que olhasse o
  arquivo inteiro acusaria 20 casos, dos quais 16 são corretos — e um gate que grita sobre o certo
  é um gate que alguém desliga.
  """

  use ExUnit.Case, async: true

  # `remove(`, `drop table`, `drop constraint` e `rename` — as quatro formas que quebram a versão
  # anterior do app. `drop index` fica de fora de propósito: índice não é contrato de leitura, e
  # remover um degrada plano sem produzir erro.
  @destrutivo ~r/^\s*(remove|remove_if_exists)\(|^\s*drop\s+table|^\s*drop\s+constraint|^\s*rename\s/m

  @marca ~r/#\s*expand-contract:\s*\S+/

  # As que já estavam no repositório quando o gate entrou (2026-08-04). Ficam de fora porque
  # **já rodaram em produção** — anotá-las retroativamente seria mexer em artefato aplicado, que é
  # justamente o que `.claude/rules/migrations.md` desaconselha, e não mudaria nada do que já
  # aconteceu. O gate existe para as próximas.
  #
  # Esta lista NÃO cresce. Se ela crescer, alguém contornou o gate em vez de usá-lo.
  @anteriores_ao_gate ~w(
    20260724040348_remove_clinic_falta_consome_padrao.exs
    20260726205405_remove_appointment_package_id.exs
    20260731235302_remover_confirmacao_na_criacao.exs
    20260801052728_remover_lembrete_ao_paciente.exs
  )

  @diretorio "priv/repo/migrations"

  test "migration nova com operação destrutiva no `up` declara a fase de expand-contract" do
    arquivos = File.ls!(@diretorio) |> Enum.filter(&String.ends_with?(&1, ".exs")) |> Enum.sort()

    # Anti-vacuidade: se o diretório mudar de lugar, o `for` abaixo não olharia nada.
    assert length(arquivos) > 50, "achei só #{length(arquivos)} migrations — o caminho mudou?"

    for arquivo <- arquivos, arquivo not in @anteriores_ao_gate do
      fonte = File.read!(Path.join(@diretorio, arquivo))

      if Regex.match?(@destrutivo, bloco_up(fonte)) do
        assert Regex.match?(@marca, fonte),
               """
               `#{arquivo}` remove ou renomeia algo no `up` e não declara a decisão.

               Enquanto o `migrate` roda, o container ANTERIOR da API ainda serve tráfego contra o \
               schema já migrado (compose.dokploy.yml recria em ordem de dependência). Uma coluna \
               removida na fase errada produz erro em toda query que a mencione, durante a janela \
               inteira do deploy — e hoje há usuário dentro dela.

               Se a mudança é segura, diga por quê, na própria migration:

                   # expand-contract: fase 3 — a coluna deixou de ser lida na release <x>, que já
                   # está em produção há <n> deploys.

               Isto NÃO prova que a mudança é segura; prova que alguém decidiu. Ver docs/59 §8.
               """
      end
    end
  end

  # A lista de grandfather é um débito com data, não um mecanismo. Se ela crescer, o gate virou
  # burocracia que se contorna — e este teste avisa antes disso virar hábito.
  test "a lista de migrations anteriores ao gate não cresceu" do
    assert length(@anteriores_ao_gate) == 4,
           """
           `@anteriores_ao_gate` tem #{length(@anteriores_ao_gate)} entradas, e nasceu com 4.

           Acrescentar migration a essa lista é contornar o gate em vez de usá-lo. O caminho certo \
           para uma migration NOVA é a marca `# expand-contract:` com a justificativa.
           """

    for arquivo <- @anteriores_ao_gate do
      assert File.exists?(Path.join(@diretorio, arquivo)),
             "`#{arquivo}` está na lista de grandfather e não existe mais — remova a entrada"
    end
  end

  # Só o corpo do `up`. Migrations do Ash sempre têm `def up`/`def down` separados; se um dia
  # aparecer uma com `def change`, o corpo inteiro é considerado (mais rigoroso, não menos).
  defp bloco_up(fonte) do
    case Regex.run(~r/\n  def up do\n(.*?)\n  end\n/s, fonte) do
      [_todo, corpo] -> corpo
      nil -> fonte
    end
  end
end
