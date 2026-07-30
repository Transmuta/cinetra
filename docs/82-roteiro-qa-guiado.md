# 82 — Roteiro de QA guiado: a aplicação inteira, fluxo a fluxo

**Fecha o `AN-13`** (doc 64 / HOM-030): o roteiro §06 do relatório da Andreza, expandido para o
produto inteiro como ele é **hoje** — cada fluxo com os cenários felizes, os de recusa e os de
robustez (sessão expirada, rede instável, concorrência), que nunca foram testados pela ótica do
usuário. Serve para rodar **com** a Andreza (re-homologação) ou como passada interna antes de
release.

**Como usar:**

- Marque `[x]` no que passou; anote o desvio ao lado do que falhou (**print + passo + horário**
  — a trilha de auditoria ajuda a reconstituir).
- "Esperado" cita a regra que o define (decisão/doc). Se o esperado parecer errado, a discussão
  é sobre a **decisão**, não sobre o bug — anote e siga.
- Cada seção diz **com que papel** rodar. Quando não diz, use a dona.
- Bug achado aqui segue a regra da casa: **vira teste de regressão antes do conserto**
  (CLAUDE.md).

---

## 0. Preparo do ambiente

Stack local (`docker compose up`) ou HML. Atenção a três armadilhas de ambiente:

- [ ] **`RESEND_API_KEY` fora do `.env`** em dev/local — com ela, o mailer real assume, o
      `/dev/mailbox` fica vazio e **nenhum magic link aparece** (doc 80 §4). Em HML ela fica, e
      os links chegam por e-mail de verdade.
- [ ] Dois browsers (ou um normal + um anônimo): os fluxos de **tempo real** e **concorrência**
      pedem duas sessões simultâneas.
- [ ] Um celular (ou DevTools em 390px) para a passada mobile do §14.

**Personagens** (criar no §1; e-mails reais em HML, `+sufixo` funciona):

| Persona | Papel | Uso |
| --- | --- | --- |
| Dona | `owner` | tudo |
| Ana | `admin` | contraprova de gestão |
| Rafael | `profissional` (vinculado a uma coluna) | recortes A7/A9 e telas só-leitura |
| Bia | `recepcao` | o balcão: agenda, ficha, fila |

---

## 1. Conta, sessão e onboarding

*Papel: visitante → dona.*

- [ ] **Criar conta** em `/criar-conta` (nome + e-mail) → tela neutra "verifique seu e-mail"
      **sem revelar** se a conta existia (ADR-015).
- [ ] **Magic link** do e-mail loga e cai no onboarding; criar a clínica → vira `owner` com os
      5 tipos de atendimento semeados.
- [ ] **Magic link usado de novo** (mesmo link) → recusado, com caminho para pedir outro.
- [ ] **Link velho** (peça dois; use o primeiro) → o mais recente vale; o consumido não.
- [ ] **Google**: "Continuar com Google" completa o ciclo e cai logado (o botão navega página
      inteira — não pode dar 404).
- [ ] **Errar o e-mail** no login → mesma tela neutra (nada de "conta não existe").
- [ ] **Rate limit**: ~6 pedidos de link seguidos → **429** com mensagem civilizada, não 500.
- [ ] **/perfil**: editar o nome (reflete no menu), e-mail read-only; **"Sair de todos os
      dispositivos"** derruba a sessão do segundo browser (confira: F5 lá → `/entrar`).
- [ ] **Sign-out** limpa a sessão; voltar com o botão "voltar" do browser não reabre tela
      autenticada com dado.

### Sessão expirada no meio do trabalho (o cenário que a Andreza pediu)

- [ ] Abra o formulário de paciente, preencha, **revogue a sessão no outro browser** (sair de
      todos), então salve → o app leva ao login **sem estourar** (500/tela branca reprovam);
      anote se o que foi digitado se perde silenciosamente.
- [ ] Mesmo teste na agenda: drawer aberto, sessão morta, clique em "Registrar status" →
      recusa limpa + caminho de volta.

---

## 2. Equipe, papéis e a matriz de acesso

*Papel: dona (e cada convidado no seu browser).*

- [ ] **Convidar** Ana (admin), Rafael (profissional **vinculado** a um profissional do
      diretório) e Bia (recepção) por e-mail; o convite chega e o aceite loga.
- [ ] **Reenviar convite** para um e-mail pendente → novo link chega e o velho não vale.
- [ ] **Matriz "o que cada papel pode"** aparece em Configurações › Equipe e bate com a
      realidade (os §§ seguintes provam célula a célula).
- [ ] **Trocar papel** de um membro ativo → reflete no próximo request (sem exigir re-login).
- [ ] **Revogar acesso** de Bia → a sessão dela morre no próximo clique; re-convidar funciona.
- [ ] **≥1 owner**: tentar rebaixar/remover a única dona → recusado com explicação.
- [ ] Profissional/recepção acessando `/configuracoes/equipe` direto pela URL → **403** da
      tela, não tela vazia.

---

## 3. Configurações da clínica

*Papel: dona; contraprova com Bia (só leitura ou 403).*

- [ ] **Dados** (`/configuracoes/clinica`): editar nome/CNPJ/endereço → o topo do sidebar
      reflete. **CNPJ alfanumérico** (novo Serpro) é aceito; CNPJ com DV errado é recusado.
- [ ] **Horários** (`/configuracoes/horario`): mudar o expediente de um dia → a hachura da
      agenda acompanha; **fechar um dia que tem agendamento futuro** → prévia de impacto com
      contagem real e **bloqueio absoluto** ou modal de conflitos (doc 48 §5) — nunca grava em
      silêncio por cima de sessão marcada.
- [ ] **Exceções** (feriado/data): criar uma exceção na data de um agendamento → mesmo gate de
      impacto; excluir exceção volta o expediente.
- [ ] **Tipos** (`/configuracoes/tipos`): criar tipo com **nome repetido** → recusado; arquivar
      tipo em uso → some do modal de criar, mas os agendamentos existentes seguem íntegros;
      restaurar traz de volta.
- [ ] **Comunicação** (`/configuracoes/comunicacao`): canais e templates visíveis; desligar um
      canal → o botão de envio correspondente some/trava no drawer (doc 52; consertado em
      `9731fc4`).
- [ ] **Auditoria** (`/configuracoes/auditoria`): as ações desta sessão de QA aparecem (quem,
      quando, o quê, diff); **campos sensíveis redigidos**; filtros por recurso/pessoa
      funcionam; Bia/Rafael na URL direta → 403.

---

## 4. Pacientes — cadastro e ficha

*Papel: **Bia (recepção)** — desde a revisão de 2026-07-29 o balcão cria/edita/arquiva;
contraprova: Rafael só lê.*

### Cadastro (validações AN-10/11 — cenário §06 "duplicado + formatos")

- [ ] Mínimo: **nome + telefone** salvam; os demais campos ficam para depois (rodapé diz isso).
- [ ] **Sem telefone** → botão desabilitado + rodapé explica (D6). Telefone incompleto idem.
- [ ] **Fixo** é aceito, com o aviso "receberá por e-mail, não WhatsApp".
- [ ] **CPF com dígito errado** (`123.456.789-00`) → **barra o salvar** com mensagem no rodapé
      (D10); corrigir para um válido libera. `111.111.111-11` também barra.
- [ ] **E-mail sem forma de e-mail** barra; **nascimento no futuro** barra; **ano 1889** barra.
- [ ] **Duplicado por CPF**: cadastre o mesmo CPF de um paciente existente → **aviso** (não
      barra) nomeando o outro paciente.
- [ ] **Duplicado por telefone**: idem.
- [ ] **Duplicado por nome + nascimento** (o cadastro sem documento): mesmo nome e mesma data →
      aviso "já tem este nome e data de nascimento".
- [ ] **CEP**: digitar um CEP real preenche endereço/bairro/cidade/UF.

### Ficha

- [ ] Ficha aberta mostra idade calculada, telefone mascarado (reabrir **não** deixa o DDI
      virar DDD — regressão `a500e7e`), consentimentos como 2 booleanos.
- [ ] **Histórico** lista presenças (não blocos) com selo "Previsto" só no futuro; **Próximos**
      e **Pacotes** funcionam; "Agendar" leva à agenda com o paciente pré-escolhido.
- [ ] **Anexos**: upload (drag e teclado), download por URL assinada, exclusão pede confirmação
      e a trilha registra a visualização. **Logado como Rafael: a seção de anexos nem aparece**
      (única exceção ao D16), e a URL direta dá 403.
- [ ] **Arquivar** paciente → some de "ativos", segue em "inativos"; reativar volta. Excluir
      **não existe** (é decisão, não bug).
- [ ] **Busca**: por parte do nome, por dígitos do CPF (com máscara gravada), por telefone;
      paginação com "X–Y de Z" honesto sob filtro.

---

## 5. Profissionais e diretório

*Papel: dona; contraprova: Bia/Rafael só leem.*

- [ ] Criar profissional (cenário §06 "incompleto"): só nome basta — **telefone é obrigatório**
      (D6) e barra sem ele; os demais campos podem faltar.
- [ ] Cor e sigla aparecem na agenda (coluna, faixa do card, avatar).
- [ ] **Horário do profissional ⊆ clínica**: herda/custom/fechado; custom fora do expediente da
      clínica é recusado.
- [ ] **Arquivar** profissional com agenda futura → o produto avisa/impede conforme o gate de
      impacto; arquivado some do modal de criar.
- [ ] Vincular membro Rafael à coluna certa (sem vínculo, profissional **não vê agenda
      nenhuma** — A7 fail-closed; vale conferir o estado "vazio" antes do vínculo).

---

## 6. Agenda — o coração (§06 "conflitos, status, grupo")

*Papel: Bia para operar; Rafael para os recortes; dona para encaixe de contraprova.*

### Criar e mover

- [ ] Clique numa célula vazia → modal com hora/profissional pré-preenchidos; criar individual
      e criar **turma** (tipo grupo) com 2+ participantes.
- [ ] **Fora do expediente** → **bloqueio absoluto**, sem saída de encaixe (D14).
- [ ] **Conflito de horário** → 422 com a saída "**Marcar como encaixe**" (A-D2b); como
      **Rafael**, a saída de encaixe **não aparece** (A9 — e é a divergência D-H2 com o
      relatório dela: aqui **recepção pode** encaixar).
- [ ] **Arraste**: mover um bloco mantém o ponto agarrado (sem pular a duração); soltar em
      conflito abre o remarcar **já no destino** com a oferta de encaixe (nunca beco sem
      saída); soltar sobre header/calha não faz nada silenciosamente errado.
- [ ] **Remarcar** pelo drawer pergunta o **motivo** (opcional, D-H3) e o registra.

### Drawer e ciclo de vida

- [ ] Drawer mostra **dia + faixa + duração** (mobile cobre o cabeçalho — o dia tem de estar
      ali), paciente como título, profissional com registro na legenda.
- [ ] **Presença por participante** (turma): marcar 1 presente + 1 falta → o card vira
      **"1 de 2 concluídas"** (D13 — nunca a palavra "Concluído" mentindo); individual mantém
      a palavra.
- [ ] **Falta pergunta o motivo** (opcional) por participante; o motivo **reaparece** na ficha
      e no drawer depois; **justificada** é um toggle por pessoa (e é o que decide o débito do
      pacote punitivo).
- [ ] Presente/Faltou **desabilitados antes do horário** (D-E4.1); o servidor recusa mesmo se a
      UI falhar.
- [ ] **Cancelar** pergunta motivo; **reabrir** desfaz; **excluir** (lixeira) só para o que não
      aconteceu, com confirmação que explica a diferença para cancelar; o bloco some da agenda
      e dos relatórios, mas a trilha guarda.
- [ ] **Pacote no bloco**: sessão de pacote mostra o selo **"3/10"** no card individual; na
      turma, a contagem de cabeças; no drawer, o pacote **por participante** com débito (D12).
- [ ] **Quem cabe aqui** (AN-12): cancele um bloco → a seção lista candidatos da fila com
      prioridade e dias de espera; **"Agendar"** converte na vaga (paciente sai da fila, bloco
      novo nasce, `veio_da_fila` aparece no drawer novo). Numa vaga de **falta**, a conversão
      entra como **encaixe** — e Rafael nem vê o botão.
- [ ] **Enviar confirmação** dispara de verdade (o botão que mentia morreu — D-H4): a timeline
      ganha a linha, o e-mail/WhatsApp chega, e **reenviar para um participante** não dispara
      para a turma inteira.

### Visões e tempo real

- [ ] Dia/Semana/Mês/Lista consistentes entre si (contagens do Mês = blocos do Dia).
- [ ] **Legenda** (AN-01) recolhível, explica status, conflito, encaixe e a composição da
      turma.
- [ ] **Ocupação** no cabeçalho da coluna bate com a fórmula (minutos ÷ expediente).
- [ ] **Tempo real**: com dois browsers na mesma agenda, criar/mover/cancelar num aparece no
      outro **sem F5**; a presença de "quem está olhando" aparece no topo.
- [ ] **Concorrência pela UI** (§06): dois browsers abrem o MESMO bloco; um remarca; o outro
      tenta mudar status → **409 "recarregue"**, nunca sobrescrita silenciosa. E dois criando
      no mesmo horário → um leva o 422 do conflito.
- [ ] **Como Rafael**: a agenda mostra **só a coluna dele**; relatórios, fila e drawer não
      vazam colegas; tentar escrever na coluna do colega (via drag) é recusado.

---

## 7. Fila de espera (§06 "oferta → resposta → converte")

*Papel: Bia.*

- [ ] Adicionar paciente com prioridade/janela/preferências; **re-adicionar o mesmo paciente
      edita** (upsert), não duplica.
- [ ] Contagens da sidebar batem com o filtro; paginação honesta.
- [ ] **Chips de vaga** aparecem na lista (inclusive **ABRIU** para vaga de
      cancelamento/falta); clicar no chip abre a oferta **já na conversão**.
- [ ] **Oferecer** → lista de horários compatíveis → converter cria o agendamento e **tira da
      fila**; conflito no meio-tempo → saída de encaixe.
- [ ] **Sair da fila** (lixeira) remove de verdade — o registro de oferta/resposta **não
      existe** (recusado no D11; se a Andreza insistir, é decisão nova, não bug).
- [ ] O convertido mostra **"Fila de espera · esperou N dias"** no drawer (D-H10).

---

## 8. Pacotes

*Papel: Bia.*

- [ ] Criar pacote na ficha (N sessões, punitivo ou não) com **prévia ao vivo** no modal;
      conflitos aparecem antes de salvar; fora do expediente **bloqueia** (D14).
- [ ] Materialização cria as sessões; **presença debita**; **falta punitiva debita, falta
      justificada não**.
- [ ] Pausar / retomar / cancelar; **±1 sessão** e **ajustar a grade** funcionam e a trilha da
      ficha conta a história (`f480017`).
- [ ] Turma: participantes de pacotes **diferentes** no mesmo bloco mostram cada um o seu no
      drawer.

---

## 9. Comunicação com o paciente

*Papel: Bia; caixa de e-mail/WhatsApp do "paciente" à mão.*

- [ ] Confirmação chega com os dados certos (data local! — conferir fuso) e o paciente
      **responde pelo link assinado**: confirmar e cancelar refletem na agenda.
- [ ] Link adulterado/expirado → recusa limpa, sem vazar dado.
- [ ] **Opt-out por canal** na ficha → o envio respeita na hora (o botão trava/explica).
- [ ] Paciente **só com fixo** → sai por e-mail (a UI avisou no cadastro).
- [ ] Lembretes automáticos (se ligados em HML): chegam na antecedência configurada; remarcação
      e cancelamento disparam o aviso certo (fase 2, doc 65).

---

## 10. Notificações in-app

- [ ] Sino com badge; **fan-out por papel** (mudança na agenda do Rafael notifica o Rafael;
      quem fez a ação **não** se auto-notifica).
- [ ] **Vaga-com-fila**: cancelar bloco com fila compatível notifica quem opera.
- [ ] Convite aceito notifica a dona.
- [ ] Badge cai **sem F5** ao ler; "ler todas" e "limpar tudo" funcionam; abas Todas/Não lidas.
- [ ] A caixa é **por usuário**: as notificações da Bia não aparecem para a Ana.

---

## 11. Relatórios (§06 "números batem")

*Papel: dona; contraprova Rafael.*

- [ ] Volume/concluídos/faltas/cancelados batem com o que o §6 deste QA criou (conte na mão —
      é o teste que a Andreza fará).
- [ ] **Fórmula visível** em cada KPI (AN-05) — o ícone de ajuda é botão: abre um diálogo com a
      conta. Ocupação é minutos ÷ expediente, não "slots".
- [ ] **No celular** (ACC-10): tocar o ícone abre a mesma explicação. Sem hover não há outro
      caminho — se o toque não abrir nada, o número volta a ser incontestável por falta de conta.
- [ ] Excluído (soft-delete) **não conta**; cancelado conta como cancelado.
- [ ] **Rafael** vê só os próprios números; o filtro de profissional para ele nem oferece os
      colegas.

---

## 12. RBAC transversal — a matriz ao vivo

*Rodar a MESMA bateria curta logado com cada persona; o esperado é a linha da matriz da tela
de Equipe (AN-06).*

| Ação | Dona | Ana (admin) | Rafael (prof.) | Bia (recepção) |
| --- | --- | --- | --- | --- |
| Criar/mover agendamento | ✅ | ✅ | ✅ só na própria coluna | ✅ |
| Marcar **encaixe** | ✅ | ✅ | ❌ | ✅ |
| Criar/editar ficha de paciente | ✅ | ✅ | ❌ (só lê) | ✅ *(revisão 2026-07-29)* |
| Ver **anexos** | ✅ | ✅ | ❌ | ✅ |
| Fila: adicionar/converter | ✅ | ✅ | ✅ | ✅ |
| Pacotes: criar/operar | ✅ | ✅ | ✅ | ✅ |
| Profissionais/tipos: editar | ✅ | ✅ | ❌ | ❌ |
| Horários/exceções: editar | ✅ | ✅ | ❌ | ❌ |
| Dados da clínica: editar | ✅ | ✅ | ❌ | ❌ |
| Equipe: convidar/papéis | ✅ | ✅ | ❌ (403) | ❌ (403) |
| Auditoria: ler | ✅ | ✅ | ❌ (403) | ❌ (403) |
| Relatórios | ✅ | ✅ | só os próprios | ✅ |

- [ ] Cada ❌ recusa **limpo** (403/tela de erro ou controle ausente), nunca 500.
- [ ] **Multi-clínica**: crie uma 2ª clínica com a mesma dona; trocar de clínica muda TODO o
      conteúdo (agenda, pacientes, fila) e **nada da clínica A aparece na B** — inclusive nas
      notificações e na busca.

---

## 13. Robustez — rede instável e afins (§06)

- [ ] **Offline no meio do form** (DevTools → Offline): salvar paciente → erro **civilizado**
      (toast/rodapé), o digitado **não se perde**; voltar online e salvar funciona.
- [ ] **Offline na agenda**: mover bloco → o bloco **volta** ao lugar com aviso (nunca fica
      "movido" só na tela); o tempo real **ressincroniza** ao reconectar (crie algo no outro
      browser durante o offline e confira que aparece).
- [ ] **Duplo clique** em qualquer botão de ação → **uma** operação só (o "está indo" do
      `4e0e020` trava o segundo clique).
- [ ] **Lentidão** (DevTools → Slow 3G) na prévia do pacote e na busca de paciente → estados de
      "carregando" aparecem; respostas fora de ordem não sobrescrevem a mais nova.
- [ ] **F5 no meio de tudo**: cada tela volta ao estado do servidor sem erro (drawer aberto,
      modal aberto, filtros na URL sobrevivem).

---

## 14. Mobile e acessibilidade (passada rápida)

*O gate formal de a11y é o doc 80; aqui é o smoke de usuário.*

- [ ] **Celular**: agenda utilizável (navegar dias, abrir drawer — que cobre a tela e mostra o
      DIA), criar agendamento, ficha de paciente, fila. Sem scroll horizontal.
- [ ] **Teclado**: Tab percorre o login e os formulários; **Esc fecha** modal/drawer; abrir
      diálogo move o foco para dentro e fechar devolve ao gatilho (doc 80 §2.4). Limitação
      conhecida: **criar agendamento ainda não tem caminho por teclado** (doc 80 §3.5) — não é
      achado novo.
- [ ] **Zoom 200%**: login, agenda e ficha continuam operáveis.
- [ ] **Dark mode**: sem flash ao carregar; badges e chips legíveis nos dois temas (as
      pendências de contraste conhecidas estão no doc 80 §3 — anotar só o que for NOVO).

---

## 15. Landing e páginas públicas

- [ ] `/` carrega rápido, links funcionam, CTA leva a `/criar-conta`.
- [ ] `/privacidade` e `/termos` existem, com a nota de aceite no cadastro (doc 81) — conferir
      que os dados do controlador **ainda são placeholders** antes de qualquer go-live.
- [ ] 404 de rota inexistente é a página de erro do app, não stack trace.

---

## 16. O que anotar para a conversa com a Andreza

Além dos desvios achados, levar desta rodada (ver doc 64 §7):

1. A **planilha de backlog editável** e o **HOM-007** (ausente do relatório) — pendências dela.
2. As respostas dadas: HOM-008 rejeitado (D-H2 — recepção encaixa), HOM-022/023/026/027 fora
   por decisão, D-H6 ii/iii recusados.
3. As **mudanças desde o relatório dela**: recepção edita ficha (revisão pós-matriz), matriz de
   acesso publicada, pacotes existem de verdade, WhatsApp envia de verdade.
4. As **decisões de paleta** do doc 80 §3 (contraste AA × identidade), se ela opina em UX.
