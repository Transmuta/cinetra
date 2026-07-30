defmodule ApiWeb.Router do
  use ApiWeb, :router
  use AshAuthentication.Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Sessão + escopo (ADR-014): carrega o usuário da sessão e monta o `Api.Scope`
  # (actor + tenant ativo). Toda rota que fala com o domínio passa por aqui.
  pipeline :authenticated do
    plug :fetch_session
    plug :load_from_session
    # Binding jti↔sub: barra forja "meu jti + sub de outro" sob secret vazada. Roda antes
    # do LoadScope para rejeitar a sessão antes de montar o escopo.
    plug ApiWeb.Plugs.VerifyTokenSubject
    plug ApiWeb.Plugs.LoadScope
  end

  # Fluxo OAuth (Assent): precisa da sessão para o parâmetro de state.
  pipeline :oauth do
    plug :fetch_session
  end

  # Rate limiting dos endpoints de auth (auditoria doc 13, causa A). No-op fora de produção.
  pipeline :rate_limited do
    plug ApiWeb.Plugs.RateLimitAuth
  end

  # Rate limit do tráfego geral, em DOIS estágios (doc 68, causa C).
  #
  # `:rate_limited_edge` vem ANTES do `:authenticated` e corta enxurrada por IP com teto folgado
  # (400/min). Sem ele, cada requisição barrada ainda pagava as 5 queries da stack de sessão —
  # medido: 42× de amplificação, 27 s de banco por minuto descartados.
  #
  # `:rate_limited_global` vem DEPOIS, quando já existe escopo, e aplica o limite fino de 200/min
  # por ator. Fora dos dois: os endpoints de auth (limite próprio), os health checks (liveness não
  # pode depender do rate limiter, doc 62 §7.1) e os webhooks (rajada legítima de campanha; a
  # guarda deles é a assinatura). No-op fora de produção.
  pipeline :rate_limited_edge do
    plug ApiWeb.Plugs.RateLimitGlobal, stage: :edge
  end

  pipeline :rate_limited_global do
    plug ApiWeb.Plugs.RateLimitGlobal, stage: :actor
  end

  # AshJsonApi (recursos do domínio) — sob :authenticated, então cada request já chega
  # com actor e `clinic_id` (tenant) resolvidos do escopo, nunca do corpo/URL (09 §8).
  scope "/api/json" do
    pipe_through [:api, :rate_limited_edge, :authenticated, :rate_limited_global]

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 4

    forward "/", ApiWeb.AshJsonApiRouter
  end

  # Endpoints de auth com rate limit (auditoria doc 13, causa A): os que geram e-mail/token
  # ou trocam de tenant. No-op fora de produção.
  scope "/api", ApiWeb do
    pipe_through [:api, :rate_limited_edge, :authenticated, :rate_limited]

    # Autenticação sem senha (ADR-015, contrato 09 §8).
    post "/auth/magic-link", AuthController, :request_magic_link
    get "/auth/google", AuthController, :google
    post "/auth/switch-tenant", AuthController, :switch_tenant
  end

  # Health checks — fora do `:authenticated` de propósito (doc 62 §7.1). Passar pelo pipeline de
  # sessão acoplaria o liveness à stack de autenticação: uma falha no `load_from_session` faria o
  # orquestrador reiniciar uma instância que está viva. Liveness só pode depender do BEAM.
  scope "/api", ApiWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/ready", HealthController, :ready
  end

  scope "/api", ApiWeb do
    pipe_through [:api, :rate_limited_edge, :authenticated, :rate_limited_global]

    # Onboarding do primeiro acesso: cria a clínica + owner (ADR-016). clinic_id nasce aqui.
    post "/clinics", ClinicController, :onboard

    get "/auth/magic-link/callback", AuthController, :magic_link_callback
    get "/auth/me", AuthController, :me
    # Tela "Meu perfil" (identidade global, sem tenant): editar o próprio nome e sair de todos
    # os dispositivos. `PATCH /auth/me` espelha o `GET /auth/me`; o alvo é sempre o próprio ator.
    patch "/auth/me", AuthController, :update_profile
    delete "/auth/sign-out", AuthController, :sign_out
    post "/auth/sign-out-everywhere", AuthController, :sign_out_everywhere

    # Token efêmero de WebSocket (ADR-014, 09 §8).
    get "/realtime/token", AuthController, :realtime_token

    # Dados da clínica ativa (tela /configuracoes/clinica): nome, CNPJ, endereço. Leitura para
    # todo membro; edição só owner/admin. clinic_id sempre do escopo (nunca no path/corpo).
    get "/clinic", ClinicController, :show
    patch "/clinic", ClinicController, :update

    # Comunicação com o paciente (doc 52 §7). Rota própria pelo mesmo motivo da ação: o que a
    # fronteira aceita é o que a ação aceita, não o que o formulário desenha.
    patch "/clinic/messaging", ClinicController, :update_messaging

    # A matriz "o que cada papel pode" (AN-06) — resumo das policies, com tripwire de teste.
    get "/access-matrix", AccessMatrixController, :show

    # Gestão de membros (Fatia 10 / Equipe & acessos). RBAC owner/admin no controller +
    # policies do Membership; clinic_id sempre do escopo.
    get "/members", MembersController, :index
    post "/members", MembersController, :create
    patch "/members/:id", MembersController, :update
    delete "/members/:id", MembersController, :delete

    # Catálogo de tipos de atendimento (doc 20). Leitura para todo membro, escrita só
    # owner/admin (controller + policies); clinic_id sempre do escopo.
    get "/appointment-types", AppointmentTypesController, :index
    post "/appointment-types", AppointmentTypesController, :create
    patch "/appointment-types/:id", AppointmentTypesController, :update
    # Arquivar/restaurar são transição de estado, não destroy (T2/T10): POST /:id/<verbo>.
    post "/appointment-types/:id/archive", AppointmentTypesController, :archive
    post "/appointment-types/:id/restore", AppointmentTypesController, :restore

    # Horário semanal da clínica (doc 22). Leitura para todo membro, escrita só owner/admin;
    # clinic_id sempre do escopo. PATCH substitui a semana enviada.
    get "/clinic-hours", ClinicHoursController, :index
    patch "/clinic-hours", ClinicHoursController, :update

    # Exceções de data da clínica (doc 22). Excluir é DELETE de verdade (H4).
    get "/clinic-exceptions", ClinicExceptionsController, :index
    post "/clinic-exceptions", ClinicExceptionsController, :create
    delete "/clinic-exceptions/:id", ClinicExceptionsController, :delete

    # Diretório de profissionais (fatia Profissionais). Leitura para todo membro, escrita só
    # owner/admin; clinic_id sempre do escopo. Ficha, grade semanal e exceções de data são
    # superfícies separadas (o web orquestra). Arquivar é POST /:id/deactivate, não destroy.
    get "/professionals", ProfessionalsController, :index
    post "/professionals", ProfessionalsController, :create
    get "/professionals/:id", ProfessionalsController, :show
    patch "/professionals/:id", ProfessionalsController, :update
    post "/professionals/:id/deactivate", ProfessionalsController, :deactivate
    post "/professionals/:id/reactivate", ProfessionalsController, :reactivate
    patch "/professionals/:id/hours", ProfessionalsController, :update_hours
    post "/professionals/:id/exceptions", ProfessionalsController, :create_exception

    delete "/professionals/:id/exceptions/:exception_id",
           ProfessionalsController,
           :delete_exception

    # Cadastro de pacientes (fatia Pacientes). Leitura para todo membro, escrita só owner/admin;
    # clinic_id sempre do escopo. A ficha inteira num corpo só. Arquivar é POST /:id/deactivate,
    # não destroy — Pacotes/Attendance/Fila apontarão para cá.
    get "/patients", PatientsController, :index
    post "/patients", PatientsController, :create
    get "/patients/:id", PatientsController, :show
    patch "/patients/:id", PatientsController, :update
    post "/patients/:id/deactivate", PatientsController, :deactivate
    post "/patients/:id/reactivate", PatientsController, :reactivate

    # Pacotes (Fatia 3, doc 09). `preview` classifica a série sem escrever (save-gate); `create`
    # decide server-side e enfileira a materialização. Pausar/cancelar operam sobre a série. A
    # lista mora sob o paciente (a ficha). `clinic_id` sempre do escopo.
    get "/patients/:patient_id/packages", PackagesController, :index
    # Histórico de sessões da ficha (C13, Frente 7) — por PRESENÇA, não por bloco.
    get "/patients/:patient_id/history", PatientsController, :history

    # Anexos da ficha (doc 51). Owner·admin·recepção — o `profissional` NÃO acessa, e por isso o
    # controller tem guarda própria em vez das duas de `TenantScope`. Nenhum byte passa por aqui:
    # o browser sobe e baixa direto do R2 por URL assinada de vida curta.
    get "/patients/:patient_id/attachments", AttachmentsController, :index
    post "/patients/:patient_id/attachments", AttachmentsController, :create
    post "/attachments/:id/confirm", AttachmentsController, :confirm
    get "/attachments/:id/download", AttachmentsController, :download
    patch "/attachments/:id", AttachmentsController, :update
    delete "/attachments/:id", AttachmentsController, :delete
    post "/packages/preview", PackagesController, :preview
    post "/packages", PackagesController, :create
    post "/packages/:id/pause", PackagesController, :pause
    post "/packages/:id/resume", PackagesController, :resume
    post "/packages/:id/cancel", PackagesController, :cancel
    # Arquivar (D1, doc 69): a única porta para `:concluido` — nada fecha o pacote sozinho.
    post "/packages/:id/archive", PackagesController, :archive

    # O `+1`/`−1` do ADR-011 (não há renovação: o total é editável) e a grade (contrato 09:441).
    # O `−1` não recebe id de sessão: quem escolhe é o servidor (a última FUTURA, D3).
    get "/packages/:id/sessions", PackagesController, :sessions
    post "/packages/:id/sessions", PackagesController, :add_session
    delete "/packages/:id/sessions", PackagesController, :remove_session
    patch "/packages/:id/grade", PackagesController, :adjust_grade
    # Massa por pacote (doc 41 etapa 3): opera sobre as PRESENÇAS do pacote, não sobre o bloco.
    post "/packages/:id/bulk_adjust", PackagesController, :bulk_adjust
    post "/packages/:id/bulk_cancel", PackagesController, :bulk_cancel

    # Agenda (doc 25). Papéis owner·admin·recepcao·profissional (A8) — recepção é quem agenda,
    # e o profissional só enxerga a própria agenda (A7, recorte por linha na preparation).
    # `clinic_id` sempre do escopo; `ends_at` é derivado e não entra no corpo.
    # Antes de `/appointments/:id` (que a Entrega 4 traz): rota literal precede a paramétrica,
    # senão "counts" vira um id e a leitura da semana responde 404.
    get "/appointments/counts", AppointmentsController, :counts
    get "/appointments", AppointmentsController, :index
    post "/appointments", AppointmentsController, :create

    # Um bloco por id — resolve o link do drawer (`/agenda?agendamento=<id>`), onde quem recebe
    # o link não sabe em que dia o bloco está. Depois de `/counts` pela mesma razão de sempre.
    get "/appointments/:id", AppointmentsController, :show

    # Ciclo de vida (Entrega 4): ações nomeadas, uma rota por transição (doc 25 §3).
    patch "/appointments/:id/reschedule", AppointmentsController, :reschedule
    post "/appointments/:id/cancel", AppointmentsController, :cancel
    post "/appointments/:id/reopen", AppointmentsController, :reopen
    post "/appointments/:id/exclude", AppointmentsController, :exclude

    # Comunicação com o paciente (doc 52 §6). A timeline é leitura de qualquer membro (com o
    # recorte A7 na preparation do recurso); o disparo é dos papéis que agendam, guardado no
    # próprio controller.
    get "/appointments/:appointment_id/messages", MessagesController, :index
    post "/appointments/:appointment_id/messages", MessagesController, :create

    # Presença por participante (Frente 6/A2, doc 41 / 09 §3.1.1). Sub-rota do bloco.
    post "/appointments/:id/participants/:patient_id/complete",
         AppointmentsController,
         :participant_complete

    post "/appointments/:id/participants/:patient_id/no_show",
         AppointmentsController,
         :participant_no_show

    post "/appointments/:id/participants/:patient_id/reopen",
         AppointmentsController,
         :participant_reopen

    post "/appointments/:id/participants/:patient_id/justify",
         AppointmentsController,
         :participant_justify

    # Cálculo, não coleção (09:253): a composição das 4 camadas de expediente.
    get "/availability", AvailabilityController, :index

    # Relatórios (Fatia 9, doc 33). Agregado de período; leitura para todo membro, com o recorte
    # do papel `profissional` vindo de `OwnAgendaOnly` (dados, não 403). `clinic_id` do escopo.
    get "/reports/summary", ReportsController, :summary

    # Fila de espera (Entrega 5, doc 09 §3.6). As rotas com sufixo (`/slots`, `/convert`) vêm
    # antes da paramétrica pura pela mesma razão de `/appointments/counts`.
    get "/waitlist", WaitlistController, :index
    # Literais antes da paramétrica: "candidates"/"slots" não podem virar um `:id`.
    get "/waitlist/candidates", WaitlistController, :candidates
    get "/waitlist/slots", WaitlistController, :all_slots
    post "/waitlist", WaitlistController, :create
    get "/waitlist/:id/slots", WaitlistController, :slots
    post "/waitlist/:id/convert", WaitlistController, :convert
    patch "/waitlist/:id", WaitlistController, :update
    delete "/waitlist/:id", WaitlistController, :delete

    # Notificações in-app (doc 31). Leitura para todo membro (cada um só vê a própria caixa, pela
    # policy do recurso); "marcar lida" é a única escrita da UI. `clinic_id` sempre do escopo.
    get "/notifications", NotificationsController, :index
    # Rota própria para o badge: é o endpoint mais chamado do sistema (roda no load do layout,
    # em toda navegação) e a única coisa que ele precisa devolver é um número.
    get "/notifications/unread-count", NotificationsController, :unread_count
    # Literal antes da paramétrica: "read-all" não pode virar um `:id`.
    post "/notifications/read-all", NotificationsController, :mark_all_read
    post "/notifications/:id/read", NotificationsController, :mark_read
    # Esvaziar a caixa: DELETE na coleção — some a caixa inteira do dono, não uma linha.
    delete "/notifications", NotificationsController, :clear_all

    # Trilha de auditoria (doc 25 §11.4, tela /configuracoes/auditoria). Owner·admin only —
    # a guarda vive no controller (with_admin_scope) e nas policies do recurso de versão.
    # `clinic_id` sempre do escopo; a página e os filtros viajam na query string.
    get "/audit", AuditController, :index
  end

  # Comunicação com o paciente (doc 52): as duas rotas **sem sessão** desta fatia. Não passam
  # por `:authenticated` porque quem chega aqui não tem login — é o provider de e-mail e é o
  # próprio paciente. O que autoriza cada uma está no controller: assinatura do provider num
  # caso, token assinado no outro.
  # Webhooks dos providers — **fora do rate limit global** de propósito: numa campanha grande,
  # a rajada de eventos de entrega do mesmo IP do provider estouraria os 200/min e atrasaria a
  # entrega (429 → retry). A guarda deles é a assinatura, conferida antes de qualquer leitura
  # de banco.
  scope "/", ApiWeb do
    pipe_through :api

    # Eventos de entrega. A assinatura Svix é conferida antes de qualquer leitura de banco, e o
    # corpo cru vem do `ApiWeb.Plugs.CacheRawBody` (instalado no `Plug.Parsers` do endpoint).
    post "/webhooks/resend", ResendWebhookController, :create

    # O mesmo para o WhatsApp (doc 65 §4): entrega, leitura, falha e a palavra-chave de opt-out
    # que o paciente escreve. Assinatura HMAC-SHA256 do corpo cru, não Svix.
    post "/webhooks/zernio", ZernioWebhookController, :create
  end

  scope "/", ApiWeb do
    pipe_through [:api, :rate_limited_edge, :rate_limited_global]

    # A resposta do paciente (§5). O token identifica UMA mensagem e não abre sessão nenhuma —
    # e por ser pública e sem sessão, é exatamente o tipo de rota que o limite global protege.
    get "/api/reply/:token", PatientReplyController, :show
    post "/api/reply/:token", PatientReplyController, :create
  end

  # Máquina OAuth do AshAuthentication (Assent): request + callback do Google. Chama
  # `ApiWeb.AuthStrategyController.success/4` / `failure/3`.
  scope "/" do
    pipe_through [:oauth, :rate_limited_edge, :rate_limited_global]
    auth_routes(ApiWeb.AuthStrategyController, Api.Accounts.User, path: "/api/auth/strategy")
  end

  # Preview da caixa de e-mail em dev: veja os magic links em /dev/mailbox.
  if Application.compile_env(:api, :dev_routes) do
    scope "/dev" do
      pipe_through [:fetch_session]
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
