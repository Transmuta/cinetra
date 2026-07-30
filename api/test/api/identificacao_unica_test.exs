defmodule Api.IdentificacaoUnicaTest do
  @moduledoc """
  CPF, telefone e e-mail **preenchidos** são únicos por clínica — nos dois cadastros de pessoa
  (paciente e profissional).

  Reverte a decisão original das duas fatias ("só avisar duplicados, sem `identity`", `patient.ex`
  e `professional.ex`): o aviso do formulário era conveniência e não impedia nada, e o efeito
  disso é a mesma pessoa em duas fichas — com histórico, pacotes e trilha divididos entre elas.

  Um arquivo para os dois cadastros porque a **regra é uma**. Duplicar oito testes em
  `patient_test.exs` e `professional_test.exs` seria criar a divergência de amanhã: quem
  ajustasse a régua num lugar deixaria o outro para trás.

  ## O que estes testes provam, e o que não

  Provam a regra de domínio e a canonicalização que a sustenta (máscara não cria um segundo
  "mesmo CPF"). **Não** provam o índice do banco sob RLS: o sandbox conecta como `postgres`
  (BYPASSRLS) e o `pre_check?` da identity resolve antes do INSERT. A corrida entre dois POSTs
  simultâneos é a rede de segurança do índice único, e isso se confere no banco
  (`.claude/rules/migrations.md` §3).
  """
  use Api.DataCase, async: false

  alias Api.Directory
  alias Api.Records

  # Dois CPFs com dígito verificador válido (a `CampoValido` cobra o DV antes de a unicidade
  # chegar): não se pode usar sequência inventada aqui.
  @cpf_a "123.456.789-09"
  @cpf_b "111.444.777-35"

  defp criar(:paciente, ctx, nome, attrs),
    do: Records.create_patient(nome, attrs, scope: ctx.scope)

  defp criar(:profissional, ctx, nome, attrs),
    do: Directory.create_professional(nome, attrs, scope: ctx.scope)

  defp criar!(cadastro, ctx, nome, attrs) do
    {:ok, registro} = criar(cadastro, ctx, nome, attrs)
    registro
  end

  defp atualizar(:paciente, ctx, registro, attrs),
    do: Records.update_patient(registro, attrs, scope: ctx.scope)

  defp atualizar(:profissional, ctx, registro, attrs),
    do: Directory.update_professional(registro, attrs, scope: ctx.scope)

  defp arquivar!(:paciente, ctx, registro),
    do: Records.deactivate_patient!(registro, scope: ctx.scope)

  defp arquivar!(:profissional, ctx, registro),
    do: Directory.deactivate_professional!(registro, scope: ctx.scope)

  # O erro de identity duplicada é `InvalidChanges`, que reporta em `:fields` (plural) — não em
  # `:field` como as validações de atributo. Aceitar as duas formas é o que o `error_field/1` do
  # `ApiWeb.TenantScope` faz na fronteira; aqui a asserção segue a mesma régua para que o teste
  # continue valendo se a implementação trocar de forma.
  defp erro_no_campo?({:error, %Ash.Error.Invalid{errors: errors}}, campo) do
    Enum.any?(errors, fn err ->
      campo == Map.get(err, :field) or campo in (err |> Map.get(:fields, []) |> List.wrap())
    end)
  end

  defp mensagem({:error, %Ash.Error.Invalid{errors: errors}}) do
    errors |> Enum.map_join(" | ", &Map.get(&1, :message, "")) |> String.downcase()
  end

  for cadastro <- [:paciente, :profissional] do
    describe "#{cadastro}: identificação preenchida é única na clínica" do
      @cadastro cadastro

      test "CPF repetido é recusado" do
        ctx = clinica()

        criar!(@cadastro, ctx, "Primeiro", %{cpf: @cpf_a, tel: telefone_unico()})

        erro = criar(@cadastro, ctx, "Segundo", %{cpf: @cpf_a, tel: telefone_unico()})

        assert erro_no_campo?(erro, :cpf)
        assert mensagem(erro) =~ "cpf"
      end

      test "máscara diferente é o MESMO CPF — o valor guardado é canônico (só dígitos)" do
        ctx = clinica()

        primeiro = criar!(@cadastro, ctx, "Com máscara", %{cpf: @cpf_a, tel: telefone_unico()})

        assert primeiro.cpf == "12345678909"

        erro = criar(@cadastro, ctx, "Sem máscara", %{cpf: "12345678909", tel: telefone_unico()})

        assert erro_no_campo?(erro, :cpf)
      end

      test "telefone repetido é recusado" do
        ctx = clinica()
        tel = telefone_unico()

        criar!(@cadastro, ctx, "Primeiro", %{tel: tel})

        erro = criar(@cadastro, ctx, "Segundo", %{tel: tel})

        assert erro_no_campo?(erro, :tel)
      end

      test "telefone repetido com máscara diferente também é recusado (canônico E.164)" do
        ctx = clinica()

        primeiro = criar!(@cadastro, ctx, "Primeiro", %{tel: "(11) 98123-4451"})

        assert primeiro.tel == "+5511981234451"

        erro = criar(@cadastro, ctx, "Segundo", %{tel: "11981234451"})

        assert erro_no_campo?(erro, :tel)
      end

      test "e-mail repetido é recusado, e a caixa não cria um segundo endereço" do
        ctx = clinica()

        primeiro =
          criar!(@cadastro, ctx, "Primeiro", %{email: "Ana@Example.com", tel: telefone_unico()})

        assert primeiro.email == "ana@example.com"

        erro =
          criar(@cadastro, ctx, "Segundo", %{email: "ANA@example.com", tel: telefone_unico()})

        assert erro_no_campo?(erro, :email)
      end

      test "campo em branco NÃO colide: dois cadastros sem CPF nem e-mail convivem" do
        ctx = clinica()

        primeiro = criar!(@cadastro, ctx, "Sem documento", %{tel: telefone_unico()})

        segundo =
          criar!(@cadastro, ctx, "Outro sem documento", %{
            cpf: "",
            email: "",
            tel: telefone_unico()
          })

        assert is_nil(primeiro.cpf)
        # String vazia entra como `nil`: com `""` guardado, o segundo cadastro sem CPF colidiria
        # com o primeiro no índice único e a tela recusaria a ficha por um campo que ninguém
        # preencheu.
        assert is_nil(segundo.cpf)
        assert is_nil(segundo.email)
      end

      test "a unicidade é POR CLÍNICA — a mesma pessoa pode ser cadastro de outra clínica" do
        ctx = clinica()
        outra = clinica()
        tel = telefone_unico()

        criar!(@cadastro, ctx, "Aqui", %{cpf: @cpf_a, email: "a@example.com", tel: tel})

        assert {:ok, _} =
                 criar(@cadastro, outra, "Lá", %{cpf: @cpf_a, email: "a@example.com", tel: tel})
      end

      test "ficha ARQUIVADA conta: recadastrar é recusado, e a mensagem manda reativar" do
        ctx = clinica()

        primeiro = criar!(@cadastro, ctx, "Arquivado", %{cpf: @cpf_a, tel: telefone_unico()})
        arquivar!(@cadastro, ctx, primeiro)

        erro = criar(@cadastro, ctx, "Recadastro", %{cpf: @cpf_a, tel: telefone_unico()})

        assert erro_no_campo?(erro, :cpf)
        assert mensagem(erro) =~ "arquivad"
      end

      test "editar para um valor que já é de outra ficha é recusado" do
        ctx = clinica()

        criar!(@cadastro, ctx, "Dono do CPF", %{cpf: @cpf_a, tel: telefone_unico()})
        segundo = criar!(@cadastro, ctx, "Outro", %{cpf: @cpf_b, tel: telefone_unico()})

        erro = atualizar(@cadastro, ctx, segundo, %{cpf: @cpf_a})

        assert erro_no_campo?(erro, :cpf)
      end

      test "salvar a própria ficha sem trocar a identificação continua passando" do
        ctx = clinica()

        registro =
          criar!(@cadastro, ctx, "Eu mesmo", %{
            cpf: @cpf_a,
            email: "eu@example.com",
            tel: telefone_unico()
          })

        assert {:ok, atualizado} =
                 atualizar(@cadastro, ctx, registro, %{
                   nome: "Eu Mesmo Corrigido",
                   cpf: @cpf_a,
                   email: "eu@example.com",
                   tel: registro.tel
                 })

        assert atualizado.nome == "Eu Mesmo Corrigido"
        assert atualizado.cpf == "12345678909"
      end
    end
  end
end
