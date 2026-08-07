defmodule Api.Accounts.Emails do
  @moduledoc """
  E-mails do domínio de contas. São dois, e a régua para um terceiro é alta:

    * **magic link** (ADR-015) — o único fator de autenticação por posse do e-mail. O link aponta
      para o **web** (BFF), não para a API (ADR-005): o SvelteKit em `/auth/callback` valida o
      token via API e assina a sessão no domínio do web. `web_app_url` vem do config (dev:
      http://localhost:5173);
    * **acesso removido** (#50) — o único aviso que a caixa in-app não consegue entregar, porque
      ela é por-tenant e quem saiu perdeu o vínculo que dá acesso a ela.

  O doc 31 §5 manteve e-mail fora da v1 de propósito: e-mail por evento de agenda vira spam em
  uma semana. Os dois acima escapam pelo mesmo critério — não são eventos de agenda, são eventos
  de **acesso**, e o destinatário não tem outro canal no momento em que precisa saber.

  ## Os dois saem em texto **e** HTML

  O HTML é o modelo "conta" de `Api.EmailLayout`: cabeçalho com o logo da Cinetra e nada mais,
  porque quem recebe é usuário do sistema. O texto continua escrito à mão aqui embaixo — ele não
  é o HTML raspado, é a mesma mensagem para quem lê e-mail sem HTML (e para o filtro de spam, que
  desconfia de mensagem que só existe em HTML).

  **O link continua no corpo em texto, não só no botão.** Fora a acessibilidade, é o que mantém
  os testes de autenticação capazes de extrair o token de `text_body` — e é o que salva quem lê
  no cliente que remove `<a>`.
  """
  import Swoosh.Email

  alias Api.EmailLayout

  # A marca, num lugar só.
  @marca "Cinetra"

  # O remetente vem do CONFIG (`MAIL_FROM`, via `runtime.exs`), como o do paciente sempre veio —
  # e a constante abaixo é só o placeholder de dev, para a falta da env não derrubar o envio.
  #
  # Ele já foi uma constante e só uma, e isso custou caro: `cinetra.local` não é domínio verificado
  # em provedor nenhum, então em produção o Resend recusava o magic link com 403 **antes** de a
  # mensagem existir. Como o e-mail do paciente lê o config, ele saía normal — o que apontava o
  # dedo para o lado errado do problema. Ver `Api.Messaging.PatientEmails` e o comentário do
  # `runtime.exs`; regressão em `test/api/accounts/emails_test.exs` e `test/api/mailer_config_test.exs`.
  @default_remetente {@marca, "nao-responda@cinetra.local"}

  # A caixa que uma pessoa lê, e por isso ela aparece **escrita** no corpo em vez de um
  # "responda este e-mail": o remetente é `nao-responda@`, e convidar a responder ali seria mandar
  # a mensagem para o vazio. É o mesmo endereço das páginas legais (`web/src/lib/legal.ts`).
  #
  # **Do mesmo domínio que assina o e-mail, e isso é regra, não estética.** Ele já foi
  # `contato@cinetra.app` — domínio que nunca foi registrado (NXDOMAIN, sem SOA nem NS). Além de
  # o cliente escrever para o vazio, filtro de spam resolve os domínios citados no corpo, e um
  # que não existe conta contra a entrega; foi um dos achados de 2026-08-06, quando TODO e-mail
  # estava indo para a caixa de spam. `cinetra.com.br` é o domínio verificado no Resend, assinado
  # pelo DKIM, e recebe de volta pelo Email Routing do Cloudflare.
  @contato "contato@cinetra.com.br"

  @doc """
  Monta e envia o e-mail de magic link. Recebe um `%User{}` (já existe) ou uma string
  de e-mail (ainda não existe — o primeiro acesso cria o `User`).
  """
  def send_magic_link_email(user_or_email, token) do
    address =
      case user_or_email do
        %{email: email} -> to_string(email)
        email -> to_string(email)
      end

    link = Api.web_app_url() <> "/auth/callback?" <> URI.encode_query(token: token)

    new()
    |> to(address)
    |> from(remetente())
    |> subject("Seu link de acesso ao #{@marca}")
    |> text_body("""
    Olá!

    Use o link abaixo para entrar no #{@marca} (#{validade()}):

    #{link}

    Se você não solicitou este acesso, ignore este e-mail.
    """)
    |> html_body(html_magic_link(link))
    |> Api.Mailer.deliver()
  end

  defp html_magic_link(link) do
    EmailLayout.documento(
      titulo: "Seu link de acesso ao #{@marca}",
      preheader: "Entre com um clique, sem senha. O link #{validade()}.",
      blocos: [
        EmailLayout.cabecalho_marca(),
        EmailLayout.abertura(
          "Seu link de acesso",
          "Use o botão abaixo para entrar no #{@marca}. Não existe senha para decorar: sempre que quiser entrar, a gente manda um link como este."
        ),
        EmailLayout.botao(link, "Entrar na minha conta"),
        EmailLayout.nota("Este link #{validade()}."),
        EmailLayout.caixa_url(link),
        EmailLayout.destaque(
          "#{EmailLayout.forte("Não foi você?")} Ignore este e-mail. O link só funciona para quem o abrir, e ele expira sozinho."
        ),
        EmailLayout.rodape_conta()
      ]
    )
  end

  @doc """
  Boas-vindas: a clínica acabou de ser criada (`Clinic.onboard`). Enviado pelo
  `Api.Accounts.WelcomeEmailJob`, fora do request.

  ## Ele NÃO leva magic link

  O destinatário acabou de criar a clínica — ele está logado neste instante. O botão leva ao app,
  e quem precisar entrar de novo pede o link na tela de entrar, que é o caminho de sempre. Pôr um
  token de acesso aqui seria cunhar uma credencial que ninguém pediu, num e-mail que se encaminha,
  para resolver um problema que não existe.

  ## Os três passos apontam para telas que existem

  E o texto deles diz o que o sistema faz **hoje**: o `onboard` já semeia expediente e catálogo de
  tipos (`SeedClinicHours`, `SeedAppointmentTypes`), então o passo 1 é *conferir*, não *criar do
  zero*. E a comunicação que se liga no passo 3 é confirmação/remarcação/cancelamento — o lembrete
  por relógio saiu em 2026-08-01 (`Api.Messaging.MessageKind`), e prometê-lo aqui seria vender uma
  função aposentada.

  ## Uma imperfeição conhecida

  Quem cria uma **segunda** clínica recebe "boas-vindas" de novo. Detectar "é a primeira?" exigiria
  contar vínculos do usuário, e essa leitura é por-tenant: sob RLS, feita sem GUC, ela devolve zero
  e responderia "primeira" **sempre** — um teste verde sobre uma pergunta que o banco não respondeu
  (a mesma cegueira do D-24). Preferido: o corpo do e-mail fala da clínica que acabou de nascer, e
  continua verdadeiro nos dois casos.
  """
  def send_welcome_email(%{email: address} = user, clinic_nome) when is_binary(clinic_nome) do
    new()
    |> to(to_string(address))
    |> from(remetente())
    |> subject("Sua conta da #{clinic_nome} está pronta")
    |> text_body("""
    #{com_nome("Olá", primeiro_nome(user))}!

    A #{clinic_nome} está criada no #{@marca} e já dá para usar: #{Api.web_app_url()}

    Seus três primeiros passos:

    1. Confira o expediente. Já deixamos um horário padrão e um catálogo de tipos de atendimento —
       ajuste ao que a sua clínica faz.

    2. Cadastre a equipe e os pacientes. Depois é montar a agenda e os pacotes de sessões.

    3. Ligue a comunicação. Confirmação, remarcação e cancelamento por WhatsApp ou e-mail.

    Precisa de ajuda para configurar? Escreva para #{@contato}.
    """)
    |> html_body(html_boas_vindas(user, clinic_nome))
    |> Api.Mailer.deliver()
  end

  defp html_boas_vindas(user, clinic_nome) do
    app = Api.web_app_url()

    EmailLayout.documento(
      titulo: "Sua conta da #{clinic_nome} está pronta",
      preheader: "A #{clinic_nome} está criada. Veja os três primeiros passos para começar.",
      blocos: [
        EmailLayout.cabecalho_marca(),
        EmailLayout.abertura(
          com_nome("Boas-vindas à #{@marca}", primeiro_nome(user)),
          "A sua clínica #{EmailLayout.forte(clinic_nome)} está criada e já dá para usar. Abaixo, o caminho mais curto até a primeira semana de agenda no lugar."
        ),
        EmailLayout.botao(app, "Abrir a minha agenda"),
        EmailLayout.passos("Seus três primeiros passos", [
          %{
            titulo: "Confira o expediente.",
            texto:
              "Já deixamos um horário padrão e um catálogo de tipos de atendimento — ajuste ao que a sua clínica faz.",
            url: app <> "/configuracoes/horario"
          },
          %{
            titulo: "Cadastre a equipe e os pacientes.",
            texto: "Depois é montar a agenda e os pacotes de sessões.",
            url: app <> "/profissionais"
          },
          %{
            titulo: "Ligue a comunicação.",
            texto: "Confirmação, remarcação e cancelamento por WhatsApp ou e-mail.",
            url: app <> "/configuracoes/comunicacao"
          }
        ]),
        EmailLayout.destaque(
          "#{EmailLayout.forte("Precisa de ajuda para configurar?")} Escreva para #{EmailLayout.link("mailto:" <> @contato, @contato)} que a gente ajuda a montar a sua agenda."
        ),
        EmailLayout.rodape_conta()
      ]
    )
  end

  @doc """
  Avisa quem foi removido de uma clínica (#50). Enviado pelo `Api.Accounts.AccessRevokedEmailJob`,
  fora do request.

  **O nome da clínica é obrigatório no corpo, não decoração.** O usuário é global e pode ser
  membro de várias (ADR-017); "seu acesso foi removido" sem dizer de onde deixaria a pessoa sem
  saber se ainda tem trabalho amanhã.

  Não diz **quem** removeu: isso é conversa entre pessoas, e pôr o nome de um colega num e-mail
  automático de perda de acesso cria atrito que o sistema não tem contexto para mediar.
  """
  def send_access_revoked_email(%{email: address}, clinic_nome) when is_binary(clinic_nome) do
    new()
    |> to(to_string(address))
    |> from(remetente())
    |> subject("Seu acesso a #{clinic_nome} foi removido")
    |> text_body("""
    Olá!

    Seu acesso à clínica #{clinic_nome} no #{@marca} foi removido, e você não verá mais a agenda
    nem os dados dela.

    Se você é membro de outras clínicas, elas continuam disponíveis normalmente ao entrar.

    Se isso parecer um engano, fale com quem administra a clínica.
    """)
    |> html_body(html_acesso_removido(clinic_nome))
    |> Api.Mailer.deliver()
  end

  defp html_acesso_removido(clinic_nome) do
    EmailLayout.documento(
      titulo: "Seu acesso a #{clinic_nome} foi removido",
      preheader: "Você não verá mais a agenda nem os dados da #{clinic_nome}.",
      blocos: [
        EmailLayout.cabecalho_marca(),
        EmailLayout.abertura(
          "Seu acesso foi removido",
          "Seu acesso à clínica #{EmailLayout.forte(clinic_nome)} no #{@marca} foi removido, e você não verá mais a agenda nem os dados dela."
        ),
        EmailLayout.destaque(
          "Se você é membro de outras clínicas, elas continuam disponíveis normalmente ao entrar. Se isso parecer um engano, fale com quem administra a clínica."
        ),
        EmailLayout.rodape_conta()
      ]
    )
  end

  # Mesma leitura de `Api.Messaging.PatientEmails.remetente/0` — os dois módulos que mandam e-mail
  # perguntam a mesma coisa ao config, e o `runtime.exs` responde com o mesmo valor.
  defp remetente, do: Application.get_env(:api, __MODULE__, [])[:remetente] || @default_remetente

  # A validade sai da configuração da strategy, não de um número escrito na frase. Um
  # `token_lifetime` alterado no recurso e um "30 minutos" esquecido no texto produzem o pior tipo
  # de erro de copy: o que faz o usuário culpar o próprio e-mail quando o link já morreu.
  defp validade do
    case AshAuthentication.Info.strategy!(Api.Accounts.User, :magic_link).token_lifetime do
      {n, :minutes} -> "é válido por #{n} #{plural(n, "minuto")}"
      {n, :hours} -> "é válido por #{n} #{plural(n, "hora")}"
      {n, :days} -> "é válido por #{n} #{plural(n, "dia")}"
      _outro -> "expira em breve"
    end
  end

  defp plural(1, palavra), do: palavra
  defp plural(_n, palavra), do: palavra <> "s"

  # "Marina" e não "Marina Lopes de Souza" — a mesma régua do e-mail ao paciente
  # (`Api.Messaging.Templates`): nome completo num cumprimento soa a cobrança.
  #
  # `nil` quando não há nome, e quem chama decide o que fazer com isso. `User.nome` é
  # `allow_nil?: false` e o `DefaultNomeFromEmail` preenche no registro auth-first, então esta
  # cláusula não deve acontecer — ela existe para que um dia em que aconteça o e-mail saia com
  # "Olá!" em vez de "Olá, !".
  defp primeiro_nome(%{nome: nome}) when is_binary(nome) and nome != "",
    do: nome |> String.split(" ", parts: 2) |> hd()

  defp primeiro_nome(_user), do: nil

  defp com_nome(texto, nil), do: texto
  defp com_nome(texto, nome), do: "#{texto}, #{nome}"
end
