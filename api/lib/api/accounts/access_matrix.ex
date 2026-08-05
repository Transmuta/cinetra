defmodule Api.Accounts.AccessMatrix do
  @moduledoc """
  A matriz de acesso por papel (AN-06 / D-H7, doc 64): **o que cada papel vê e altera**, área a
  área, para a tela de Configurações › Equipe — a clínica consulta na hora de convidar, em vez
  de perguntar (ou descobrir por 403).

  ## Por que mora aqui, e não em prosa no web

  A decisão do AN-06 é explícita: "a matriz precisa sair de perto das policies, não de prosa
  escrita à mão". Perto significa duas coisas:

    * **mesmo repositório de verdade** — este módulo vive no backend, ao lado dos recursos cujas
      policies ele resume, e o web só o exibe (`GET /api/access-matrix`);
    * **tripwire automático** — `access_matrix_test.exs` confere cada linha contra as funções
      `can_*?` geradas pelas próprias policies. Mudou a policy sem mudar a matriz, o teste
      quebra; a tela nunca fica dizendo o contrário do produto.

  ## O vocabulário

  Quatro níveis, do ponto de vista de quem usa a tela:

    * `:total` — vê e altera;
    * `:leitura` — só vê;
    * `:propria` — só o que é seu (a própria agenda, a própria caixa);
    * `:nao` — sem acesso.

  `:propria` diz **qual recorte de linhas**, não se a pessoa altera — os dois eixos são
  independentes, e quem os junta é o `obs` da linha. Hoje o mesmo `:propria` cobre a agenda do
  profissional (só lê, e só a dele, desde 2026-08-04) e a caixa de notificações (lê e mexe, e só
  a dela). Foi assim desde a primeira versão, em relatórios; a mudança da agenda só tornou o
  caso visível.

  Owner e admin são equivalentes em TODAS as policies de hoje (nenhuma os distingue); a matriz
  os mantém como colunas separadas porque a pergunta da tela é "que papel eu dou a esta pessoa",
  e as opções do convite são quatro.
  """

  @papeis [:owner, :admin, :profissional, :recepcao]

  @type nivel :: :total | :leitura | :propria | :nao

  @doc "As colunas, na ordem do convite."
  @spec papeis() :: [atom()]
  def papeis, do: @papeis

  @doc """
  As linhas da matriz, na ordem em que a tela exibe. `obs` é a nota de rodapé da linha — é onde
  moram as exceções que uma célula de quatro valores não expressa (o recorte da própria agenda,
  a exceção dos anexos ao D16).
  """
  @spec areas() :: [map()]
  def areas do
    [
      %{
        id: :agenda,
        label: "Agenda e presenças",
        acesso: %{owner: :total, admin: :total, profissional: :propria, recepcao: :total},
        obs:
          "Profissional só VÊ, e só a própria agenda: não lança, não remarca, não cancela e não marca presença (A7/A8)."
      },
      %{
        id: :encaixe,
        label: "Encaixes",
        acesso: %{owner: :total, admin: :total, profissional: :nao, recepcao: :total},
        obs: "Encaixe fura a grade, então é de quem responde por ela (A9)."
      },
      %{
        id: :fila,
        label: "Fila de espera",
        acesso: %{owner: :total, admin: :total, profissional: :leitura, recepcao: :total},
        obs:
          "Profissional vê a fila inteira da clínica; quem põe, tira e oferece vaga é o balcão."
      },
      %{
        id: :pacientes,
        label: "Pacientes (ficha)",
        acesso: %{owner: :total, admin: :total, profissional: :leitura, recepcao: :total},
        obs:
          "Todo papel vê a ficha completa (D16); quem cadastra e corrige é o balcão — só o profissional não edita."
      },
      %{
        id: :anexos,
        label: "Anexos do paciente",
        acesso: %{owner: :total, admin: :total, profissional: :nao, recepcao: :total},
        obs: "A única exceção ao D16: profissional não vê anexos (doc 51)."
      },
      %{
        id: :pacotes,
        label: "Pacotes",
        acesso: %{owner: :total, admin: :total, profissional: :leitura, recepcao: :total},
        obs:
          "Pacote não se apaga — cancela, e o histórico fica. Criar um pacote é agendar em série, então também é do balcão."
      },
      %{
        id: :comunicacao,
        label: "Comunicação com o paciente",
        acesso: %{owner: :total, admin: :total, profissional: :propria, recepcao: :total},
        obs: "Profissional envia e lê só nos próprios atendimentos."
      },
      %{
        id: :relatorios,
        label: "Relatórios",
        acesso: %{owner: :leitura, admin: :leitura, profissional: :propria, recepcao: :leitura},
        obs: "Profissional vê só os próprios números."
      },
      # Esta linha era "Profissionais e tipos de atendimento", com `:leitura` para o
      # profissional nas duas coisas. Em 2026-08-04 (doc 103) só a PRIMEIRA fechou para ele, e
      # uma célula não expressa dois valores — daí a divisão. Os tipos ficam porque a agenda
      # depende deles: sem o tipo não há cor, nome nem duração no bloco que ele lê.
      %{
        id: :profissionais,
        label: "Profissionais (o diretório)",
        acesso: %{owner: :total, admin: :total, profissional: :nao, recepcao: :leitura},
        obs:
          "A tela não é do profissional: ele não vê o diretório nem a própria ficha (CPF, endereço, dados bancários). O nome dele na própria coluna da agenda continua aparecendo."
      },
      %{
        id: :tipos,
        label: "Tipos de atendimento",
        acesso: %{owner: :total, admin: :total, profissional: :leitura, recepcao: :leitura},
        obs: "Todo papel lê — é o que dá cor, nome e duração ao bloco da agenda."
      },
      %{
        id: :horarios,
        label: "Horários e exceções",
        acesso: %{owner: :total, admin: :total, profissional: :leitura, recepcao: :leitura},
        obs: "Profissional não edita o próprio horário — pede a quem administra."
      },
      %{
        id: :clinica,
        label: "Dados da clínica",
        acesso: %{owner: :total, admin: :total, profissional: :leitura, recepcao: :leitura},
        obs: nil
      },
      %{
        id: :equipe,
        label: "Equipe (convites e papéis)",
        acesso: %{owner: :total, admin: :total, profissional: :nao, recepcao: :nao},
        obs: nil
      },
      %{
        id: :auditoria,
        label: "Trilha de auditoria",
        acesso: %{owner: :leitura, admin: :leitura, profissional: :nao, recepcao: :nao},
        obs: "Ninguém escreve a trilha à mão — nem a dona."
      },
      %{
        id: :notificacoes,
        label: "Notificações",
        acesso: %{owner: :propria, admin: :propria, profissional: :propria, recepcao: :propria},
        obs: "Cada um só a própria caixa."
      }
    ]
  end

  @doc "O nível de uma área para um papel — a célula da matriz (é o que o tripwire confere)."
  @spec nivel(atom(), atom()) :: nivel()
  def nivel(area_id, papel) when papel in @papeis do
    area = Enum.find(areas(), &(&1.id == area_id)) || raise "área desconhecida: #{area_id}"
    Map.fetch!(area.acesso, papel)
  end
end
