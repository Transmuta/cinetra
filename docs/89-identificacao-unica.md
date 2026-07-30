# 89 — Identificação duplicada barra: CPF, telefone e e-mail únicos por clínica

Pedido de 2026-07-29, depois de perguntar como estava: *"duplicação de cpf e telefone está
aceitando só com alerta de warning?"* → *"mudar politica, vamo bloquear cpf duplicado ou telefone
duplicado ou email duplicado, se enviado esses, eles são unico"*.

Estava, sim. As fatias de Pacientes e Profissionais decidiram **"só avisar duplicados"**, e o
moduledoc dos dois recursos dizia isso com todas as letras: *"Sem `identity` única em
CPF/telefone — o front avisa 'possível duplicado', mas não barra"*. O aviso era conveniência: não
impedia nada, e o resultado era a mesma pessoa em duas fichas, com histórico, pacotes, faltas e
trilha divididos entre elas.

Esta fatia reverte a decisão nos **dois** cadastros de pessoa.

## 1. As três decisões que o usuário tomou

Perguntei antes de escrever, porque cada uma muda o trabalho:

| Pergunta | Escolha | Consequência |
| --- | --- | --- |
| Telefone também? (é obrigatório, e mãe/filho compartilham número) | **Sim, os três** | Cadastro que hoje reusa o celular do responsável passa a ser recusado — a recepção precisa de um número por ficha |
| Vale para Profissionais? | **Sim, os dois cadastros** | Mesma régua, mesma migration; CREFITO fica de fora (forma livre demais para virar chave) |
| Ficha arquivada conta? | **Sim — bloqueia e manda reativar** | Recadastrar quem foi arquivado é recusado; o índice não olha `ativo`, e a mensagem diz o remédio |

O risco do telefone foi levantado antes da escolha e mantido: é o caso legítimo (criança sem
celular próprio, casal) que a regra recusa. Se doer no balcão, a saída natural é um escape
explícito por ficha — não afrouxar a regra inteira.

## 2. O que barra, e onde

Três `identities` por recurso, em [`patient.ex`](../api/lib/api/records/patient.ex) e
[`professional.ex`](../api/lib/api/directory/professional.ex). Com tenancy por atributo o Ash põe o
`clinic_id` na unicidade automaticamente, então é **por clínica**: a mesma pessoa pode ser paciente
de duas clínicas, e o profissional multi-clínica do [ADR-014](00-decisoes.md) continua possível.

Duas escolhas dentro delas valem registro:

- **`nils_distinct?` no default (`true`)** — ficha sem CPF é a regra, não a exceção. Dois `NULL`
  não colidem.
- **`pre_check? true`**, como nas outras quatro identities do projeto. Não é enfeite: sob RLS o
  Postgres **omite o `DETAIL`** do `unique_violation` (ele poderia vazar linha invisível), e o
  AshPostgres lê `error.postgres.detail` para transformar a violação em erro de campo — sem
  `DETAIL`, estoura `KeyError` e o 422 vira **500**. Checando antes do INSERT, o caminho normal
  nunca encosta na constraint; o índice único fica como rede de segurança da corrida entre dois
  POSTs simultâneos.

## 3. Canonicalizar não é cosmético — é o que faz a regra valer

Unicidade é **igualdade de string**. Com a máscara guardada, bastaria digitar `12345678909` em vez
de `123.456.789-09` para criar a segunda ficha da mesma pessoa; e `Ana@Example.com` passaria por
cima de `ana@example.com`.

[`Api.Changes.Canonicalizar`](../api/lib/api/changes/canonicalizar.ex) resolve os três campos na
escrita — CPF só dígitos, telefone em E.164, e-mail em minúsculas. Ela sucede a
`Api.Records.Patient.Changes.NormalizeTel`, que fazia só o telefone e só na ficha do paciente (o
telefone do **profissional** nunca passou por normalização até aqui).

Duas bordas que o módulo carrega, e que não se adivinha lendo o nome dele:

- **Vazio vira `NULL`.** Com `""` guardado, a *segunda* ficha sem CPF colidiria com a primeira, e a
  tela recusaria um cadastro por um campo que ninguém preencheu. O formulário já manda `null`, mas
  a API é superfície pública — o `""` morre no domínio, não na tela.
- **Valor irreconhecível fica como veio.** Sobrescrever `"abc"` por `nil` apagaria o que a pessoa
  digitou antes de a mensagem de erro poder mostrá-lo de volta no formulário. Quem recusa é a
  validação.

Consequência na tela: o CPF passou a ser **canônico no banco, mascarado na leitura** — a mesma
divisão que o telefone e o CNPJ da clínica já usavam. `maskCpf` entrou nos três lugares que
exibiam a coluna crua e na inicialização dos dois formulários.

**Não há backfill.** A ficha antiga com máscara vira canônica no próximo save, pela mesma ação que
canonicaliza a nova — é a opção (b) do D6, a que evitou backfill quando o telefone virou
obrigatório. Isso deixa um buraco conhecido **só onde já existe dado não-canônico**: duas linhas
antigas, uma com máscara e uma sem, não colidem no índice. No servidor não existe linha para
resolver (a instalação ainda não foi provisionada); em dev foi resolvido na mão, junto com os 9
pares de telefone e 1 de CPF que o dado de seed tinha e que impediriam a criação do índice.

### 3.1 O e-mail do **usuário** também (pedido no meio da fatia)

*"tem um ponto sobre email nos cadastro deixe sempre minusculo, esqueci dessa regra, até do
usuario também"*.

Duas coisas diferentes, e só a primeira vinha de graça: `Api.Accounts.User.email` é `:ci_string`
(citext), então `Ana@Example.com` e `ana@example.com` **comparam** iguais — o login e a identity
`unique_email` sempre estiveram certos. O que a coluna guardava era a caixa que a pessoa digitou, e
ela aparece em tudo que lê o valor cru: a lista da equipe, o destinatário do e-mail, a trilha.

O conserto é `constraints: [casing: :lower]` no **atributo**, não numa change — o cast é do tipo,
então pega de uma vez os três caminhos que criam usuário (magic link, convite por e-mail, Google) e
qualquer um que venha depois. Os três estão cobertos em
[`auth_flow_test.exs`](../api/test/api/accounts/auth_flow_test.exs), e os três estavam vermelhos
antes.

Sem backfill, e aqui isso é ainda mais barato que no §3: com citext, linha antiga em caixa alta
continua casando no login. Medido: em dev, 0 linhas em caixa alta nas três tabelas
(`users`, `patients`, `professionals`).

O `pix` do profissional ficou de fora de propósito — uma chave PIX **pode** ser um e-mail, mas
também pode ser telefone, CPF ou chave aleatória; tratá-la como e-mail seria adivinhar.

## 4. Um bug de raspão, no aviso que já existia

Ao ler o aviso de "possível duplicado" para adaptá-lo, apareceu um furo que já estava lá:

```ts
const term = cpfDigits.length === 11 ? cpfDigits : telDigits.length >= 10 ? telDigits : '';
```

O cliente escolhia **um** termo, com o CPF na frente. Com o CPF preenchido e sem colisão, telefone
repetido **não era consultado** — nenhum aviso. Isso era menor quando duplicado só avisava; virou
grave no momento em que o save passa a ser recusado, porque a recepção só descobriria no fim.

O conserto moveu a decisão para o BFF:
[`/api/patients/lookup`](../web/src/routes/api/patients/lookup/+server.ts) passou a receber os
identificadores por nome (`?cpf=&tel=&email=&nome=&nascimento=&exclude=`), sondar **todos** e
devolver o primeiro que colide, com o campo e se a ficha está arquivada. De quebra, o recorte
canônico do BFF mata um falso positivo que existia antes: a busca da API é `LIKE %termo%`, e um
fixo de 10 dígitos é sufixo de vários celulares.

O aviso mudou de tom junto — de *"Possível duplicado"* para *"celular já cadastrado na ficha de
Ana Referência — edite aquela ficha em vez de criar outra"*, com a variante que manda **reativar**
quando a ficha encontrada está arquivada.

Uma consequência no backend: a busca da lista (`?q=`) passou a olhar o **e-mail** também. Sem isso
o aviso cobriria CPF e telefone e ficaria calado justo no terceiro campo que recusa o save.

## 5. Como isto foi provado

A suíte não prova a parte que mais podia quebrar. O `pre_check?` faz uma **leitura** dentro da
transação de escrita, e leitura por-tenant sob RLS depende da GUC — que o `SetTenantGuc` põe num
`before_action`. A ordem entre os dois hooks é o que separa 422 de 500, e o sandbox roda como
`postgres` (BYPASSRLS), cego para isso ([`.claude/rules/migrations.md`](../.claude/rules/migrations.md) §3).

Então foi medido no servidor de dev, que conecta como `cinetra_app` (confirmado em
`pg_stat_activity`), com sessão de verdade obtida pelo magic link:

| Sonda | Resultado |
| --- | --- |
| POST com CPF `390.533.447-05`, depois o mesmo CPF **sem máscara** | 201, depois **422** com `field: "cpf"` |
| POST com o telefone de outra ficha, com máscara diferente | **422** com `field: "tel"` |
| POST com o e-mail de outra ficha, caixa diferente | **422** com `field: "email"` |
| Dois POSTs com `cpf: ""` e `email: ""` | **201** e **201** — vazio não colide |
| Formulário no browser: CPF que não colide + telefone que colide | O aviso aparece (era o furo do §4) |
| Submit pelo BFF | `{"type":"failure","status":422,…}` com a mensagem no formulário |

Nenhuma delas devolveu 500 — a GUC chega antes do `pre_check`.

Automatizado: [`api/test/api/identificacao_unica_test.exs`](../api/test/api/identificacao_unica_test.exs)
(20 testes, os dois cadastros pela mesma tabela de casos) + testes de fronteira nos dois
controllers, porque o erro de identity é `InvalidChanges` e reporta o campo em `:fields` (plural):
sem o fallback do `error_field/1`, o 422 sairia com `"field": null` e o formulário não saberia qual
input marcar — **teste de domínio não pega isso** (a lição do [doc 49](49-bate-volta-onda-6.md)).

Gates: `mix test` 1694/0 · `mix coveralls` 90,1% · `mix test --only rls` 0 falhas · `npm run check`
0 erros · `npm run coverage` 2259/0.

## 6. O que ficou de fora, e por quê

- **Profissionais não têm o aviso** — só o 422 no save. O formulário de profissional nunca teve o
  lookup, e a tela é usada por owner/admin algumas vezes por ano, não pelo balcão. Se incomodar, o
  endpoint do paciente é o molde.
- **CREFITO fora da unicidade** (§1).
- **Sem escape para telefone compartilhado** — é a decisão do usuário, registrada com o risco.
- **Sem backfill** (§3): o buraco existe só para linha antiga não-canônica, e não há nenhuma no
  servidor.
