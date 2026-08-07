// Tipos e rótulos da comunicação com o paciente (doc 52 §6) — o vocabulário que a timeline do
// drawer usa. Vive fora do componente porque o BFF, a página e os testes falam dele.

/**
 * Por que nada foi enviado, na forma que a API devolve (`Api.Messaging.Dispatch`).
 *
 * `sem_contato` e `canal_indisponivel` já foram o mesmo motivo, e a fusão mentia no balcão:
 * paciente com celular na ficha lia "sem e-mail nem telefone cadastrado" quando o problema era o
 * WhatsApp desligado. Um manda a recepção preencher a ficha; o outro não é da recepção.
 */
export type SemEnvio =
	| 'sem_consentimento'
	| 'sem_contato'
	| 'canal_indisponivel'
	/**
	 * O transporte está de pé, mas **esta clínica** não ligou o canal em /configuracoes/comunicacao.
	 * Separado de `canal_indisponivel` porque o conserto tem outro dono: aqui é um interruptor que a
	 * própria clínica vira, e chamar isso de "indisponível" manda abrir chamado à toa.
	 */
	| 'whatsapp_desligado'
	| 'opt_out'
	/**
	 * Já há uma mensagem deste tipo esperando na fila para esta presença.
	 *
	 * Este e os dois abaixo só aparecem na **resposta do disparo**, nunca como explicação de
	 * silêncio na timeline: lá o motivo só é calculado quando não existe mensagem nenhuma, e os três
	 * significam o contrário — só existem porque já houve mensagem.
	 */
	| 'ja_na_fila'
	/** O paciente já respondeu que vem; pedir de novo é cobrar quem já respondeu. */
	| 'ja_confirmou'
	/** A presença já recebeu o teto de confirmações (ver `LIMITE_DE_CONFIRMACOES`). */
	| 'limite_de_envios';

export type MessageStatus = 'pendente' | 'enviado' | 'entregue' | 'lido' | 'falhou' | 'descartada';

/**
 * O teto de confirmações por presença — espelho do `@limite_de_confirmacoes` do `Dispatch`.
 *
 * Duplicado do servidor **de propósito**: a tela precisa desabilitar o botão *antes* do clique, e
 * ela não tem como perguntar.
 *
 * Nada compara os dois números em runtime — o que existe é o **valor fixado por teste dos dois
 * lados**: aqui, em `messages.test.ts`, e lá, em `ApiWeb.MessagesControllerTest` ("a terceira
 * confirmação é recusada"). Mudar um lado só deixa vermelho o teste daquele lado, então a
 * divergência exige mexer no número e no teste — ato deliberado, não descuido. É a mesma forma de
 * proteção da marca `bulk_pacote` dos notifiers.
 */
export const LIMITE_DE_CONFIRMACOES = 2;

/**
 * Por que a mensagem foi tirada da fila antes de sair (`Api.Messaging.DescarteMotivo`).
 *
 * Os dois têm a mesma forma: o fato sobre o qual ela falava deixou de existir enquanto ela
 * esperava a janela de silêncio (§7) abrir.
 */
export type DescarteMotivo = 'sessao_cancelada' | 'agendamento_excluido';

export interface Message {
	id: string;
	canal: 'email' | 'whatsapp';
	kind: 'confirmacao' | 'lembrete' | 'remarcacao' | 'cancelamento';
	status: MessageStatus;
	destino: string;
	/** O motivo cru do provider — fica para o suporte, **não** é o que se mostra. */
	erro: string | null;
	/**
	 * O mesmo motivo em português e acionável ("E-mail não existe — confira o endereço na ficha").
	 * É este que vai para a tela: o provider fala inglês técnico, e quem lê a timeline é a recepção
	 * no balcão. Texto em inglês ali não informa — gera chamado de suporte.
	 */
	erro_texto: string | null;
	resposta: 'confirmou' | 'quer_remarcar' | null;
	/** Nulo do lado da API = ninguém clicou. É o que distingue "automático" de "alguém mandou". */
	automatico: boolean;
	enfileirado_em: string | null;
	/** Preenchido só quando a janela de silêncio adiou o envio — ver `previsaoDeEnvio`. */
	agendado_para: string | null;
	enviado_em: string | null;
	entregue_em: string | null;
	lido_em: string | null;
	falhou_em: string | null;
	/** Preenchido só quando a mensagem foi retirada da fila — ver `descarteTexto`. */
	descartada_em: string | null;
	descarte_motivo: DescarteMotivo | null;
	respondido_em: string | null;
	titulo: string;
}

export interface MessageParticipant {
	attendance_id: string;
	patient_id: string;
	paciente: string;
	mensagens: Message[];
	/** Preenchido só quando NÃO há mensagem nenhuma — ver `semEnvioTexto`. */
	sem_envio: SemEnvio | null;
}

export interface MessagesData {
	participantes: MessageParticipant[];
}

// O texto de cada silêncio. **Cada um leva uma ação diferente**, e é por isso que eles não
// colapsam num "não enviado": autorizar é abrir a ficha, contato é preencher um campo, opt-out é
// uma conversa com o paciente — e canal indisponível não é da recepção, é de quem opera a
// instalação. Dizer "sem telefone cadastrado" a quem tem telefone na ficha manda consertar o
// lugar errado, e a recepção fica girando na ficha até desistir.
const SEM_ENVIO_MOTIVO: Record<SemEnvio, string> = {
	sem_consentimento: 'sem consentimento de comunicação na ficha',
	sem_contato: 'sem e-mail nem telefone cadastrado',
	canal_indisponivel: 'o WhatsApp está indisponível e não há e-mail na ficha',
	whatsapp_desligado: 'o WhatsApp está desligado nas configurações e não há e-mail na ficha',
	opt_out: 'o paciente pediu para não receber',
	// Os três abaixo não pedem ação nenhuma — pelo contrário, dizem que já foi feito o que havia
	// para fazer. Some do balcão a impressão de que o clique falhou, que é o que faz a recepção
	// clicar de novo.
	ja_na_fila: 'a mensagem anterior ainda está na fila para este paciente',
	ja_confirmou: 'o paciente já confirmou presença',
	limite_de_envios: `já foram enviadas ${LIMITE_DE_CONFIRMACOES} confirmações para este paciente`
};

// O motivo cru vem da API: um átomo novo lá não pode virar `undefined` na tela.
function motivoTexto(motivo: string): string {
	return SEM_ENVIO_MOTIVO[motivo as SemEnvio] ?? 'não foi possível enviar';
}

export function semEnvioTexto(motivo: SemEnvio | null): string | null {
	return motivo ? `Nada enviado · ${motivoTexto(motivo)}` : null;
}

/**
 * A linha de quem não recebeu nada e **não tem motivo nenhum** barrando o envio — só ainda não
 * saiu comunicação para este agendamento.
 *
 * Existe porque o §6 é uma regra sobre a tela, não sobre o dado: *o silêncio é uma linha, nunca
 * ausência de linha*. Sem ela, esse participante apareceria com o nome e mais nada abaixo, e a
 * ausência lê-se como "já resolvido" — a recepção supõe que a mensagem saiu.
 *
 * Não diz "Nada enviado · <motivo>" como a irmã acima porque aqui não há motivo a explicar: nada
 * está errado, nada precisa ser consertado na ficha. Quem manda a primeira mensagem é o "Enviar
 * confirmação" do rodapé, que dispara para o bloco inteiro.
 */
export const SEM_COMUNICACAO = 'Nenhuma comunicação enviada até agora';

/** O que a API responde por participante no disparo manual (`POST .../messages`). */
export interface SendOutcome {
	patient_id: string;
	enviado: boolean;
	motivo?: string | null;
	/** Aceita, mas adiada pela janela de silêncio (§7) — não saiu ainda. */
	agendado_para?: string | null;
}

/**
 * O que dizer depois de disparar ("Enviar confirmação" no rodapé, "Reenviar" na timeline).
 *
 * Existe porque a API responde **201 com o resultado por participante**: o pedido foi aceito e o
 * envio pode ter sido pulado (sem contato, canal desligado, opt-out). Tratar 201 como sucesso
 * fazia a tela dizer "Feito" sem nada ter saído — o mesmo pecado que a timeline foi desenhada
 * para não cometer (§6): silêncio faz a recepção supor que a mensagem saiu.
 *
 * Na turma o parcial também não vira sucesso limpo — "enviada" com um participante de fora é
 * mentira para aquele participante (§3).
 */
export function textoDoEnvio(resultados: SendOutcome[]): string {
	if (resultados.length === 0) return 'Nada a enviar neste agendamento.';

	const enviados = resultados.filter((r) => r.enviado);
	const pulado = resultados.find((r) => !r.enviado);

	// Aceita ≠ entregue: dentro da janela de silêncio (§7) o disparo é ADIADO, e dizer "enviada"
	// ali é o mesmo "Feito" que não enviava, só que por outra causa. A hora exata fica na
	// timeline logo abaixo, que sabe o fuso da clínica; o toast não sabe, e prometer hora errada
	// seria pior do que não prometer nenhuma.
	const adiados = enviados.filter((r) => r.agendado_para);

	if (!pulado) {
		if (adiados.length === enviados.length) {
			return enviados.length === 1
				? 'Mensagem na fila · sai no fim do silêncio noturno'
				: `${enviados.length} mensagens na fila · saem no fim do silêncio noturno`;
		}

		return enviados.length === 1
			? 'Mensagem enviada'
			: `Mensagem enviada para ${enviados.length} pacientes`;
	}

	const porque = motivoTexto(pulado.motivo ?? '');

	return enviados.length === 0
		? `Nada enviado · ${porque}`
		: `Enviada para ${enviados.length} de ${resultados.length} · ${porque}`;
}

// O rótulo de estado que a recepção lê. `lido` some no e-mail (não usamos pixel de rastreio,
// C4), então ele só aparecerá quando o WhatsApp entrar.
const STATUS_TEXTO: Record<MessageStatus, string> = {
	pendente: 'Na fila',
	enviado: 'Enviado',
	entregue: 'Entregue',
	lido: 'Lido',
	falhou: 'Falhou',
	// "Não enviada", e não "Descartada": do balcão, o que interessa é o que o paciente recebeu (nada),
	// não o verbo interno que tirou a linha da fila.
	descartada: 'Não enviada'
};

// Cada motivo diz que a mensagem parou por uma DECISÃO, não por um defeito — sem isso "Não
// enviada" manda a recepção procurar problema onde alguém apenas cancelou o horário.
const DESCARTE_TEXTO: Record<DescarteMotivo, string> = {
	sessao_cancelada: 'a sessão foi cancelada antes de ela sair',
	agendamento_excluido: 'o agendamento foi excluído antes de ela sair'
};

/** A explicação da retirada da fila — `null` quando a mensagem não foi descartada. */
export function descarteTexto(m: Message): string | null {
	if (m.status !== 'descartada') return null;

	// Motivo novo no backend não pode virar `undefined` na tela — mesma defesa do `motivoTexto`.
	return m.descarte_motivo ? (DESCARTE_TEXTO[m.descarte_motivo] ?? null) : null;
}

const KIND_TEXTO: Record<Message['kind'], string> = {
	confirmacao: 'Confirmação',
	lembrete: 'Lembrete',
	remarcacao: 'Remarcação',
	cancelamento: 'Cancelamento'
};

const CANAL_TEXTO: Record<Message['canal'], string> = {
	email: 'e-mail',
	whatsapp: 'WhatsApp'
};

/** "Confirmação enviada por e-mail" — a primeira linha de cada item da timeline. */
export function tituloDaLinha(m: Message): string {
	return `${KIND_TEXTO[m.kind]} por ${CANAL_TEXTO[m.canal]}`;
}

export function statusTexto(m: Message): string {
	return STATUS_TEXTO[m.status];
}

/** O instante que interessa exibir: o mais avançado que a mensagem alcançou. */
export function instanteDoStatus(m: Message): string | null {
	return (
		m.descartada_em ?? m.falhou_em ?? m.lido_em ?? m.entregue_em ?? m.enviado_em ?? m.enfileirado_em
	);
}

/**
 * Quando esta mensagem ainda vai sair — ou `null` quando não há nada a prometer.
 *
 * A janela de silêncio (§7) **adia**, não descarta: uma confirmação disparada às 22h fica na fila
 * até as 8h. A tela mostrava só "Na fila" e o instante em que ela ENTROU na fila, e a leitura
 * natural disso é "não está enviando" — foi o relato do teste ao vivo de 2026-07-28, com três
 * mensagens corretamente adiadas. Silêncio inexplicado outra vez, no único estado que a fatia não
 * tinha previsto (§6).
 *
 * Só vale enquanto a mensagem está parada: depois que ela sai, o que interessa é o que aconteceu,
 * não o que se previa. E `agendado_para` no passado não vira promessa — ali o job está atrasado ou
 * em retentativa, e "sai às 8h" às 9h seria a tela mentindo com precisão.
 */
export function previsaoDeEnvio(m: Message, agora: string | number = Date.now()): string | null {
	if (m.status !== 'pendente' || !m.agendado_para) return null;

	return Date.parse(m.agendado_para) > new Date(agora).getTime() ? m.agendado_para : null;
}

const RESPOSTA_TEXTO: Record<NonNullable<Message['resposta']>, string> = {
	confirmou: 'Confirmou presença',
	quer_remarcar: 'Pediu para remarcar'
};

export function respostaTexto(m: Message): string | null {
	return m.resposta ? RESPOSTA_TEXTO[m.resposta] : null;
}

/** O tom do resumo — os mesmos tokens que o drawer já usa para presença e pacote. */
export type ComunicacaoTom = 'success' | 'danger' | 'muted' | 'faint';

export interface ComunicacaoDaPessoa {
	/** Uma frase só, o estado atual da comunicação com esta pessoa. */
	texto: string;
	tone: ComunicacaoTom;
	/** Rótulo do botão de disparo, ou `null` quando não há o que disparar agora. */
	acao: 'Enviar' | 'Reenviar' | null;
	/** Por que não há botão — vai no `title`. `null` quando há botão. */
	bloqueio: string | null;
	/** O instante a exibir ao lado do texto (ISO), ou `null`. */
	quando: string | null;
	/** `quando` é PREVISÃO (a janela de silêncio adiou), não fato consumado. */
	previsao: boolean;
}

/**
 * A comunicação com **uma** pessoa, resumida para caber na linha dela (doc 109).
 *
 * A timeline do rodapé continua sendo o histórico completo; isto é o que a recepção precisa ler
 * sem sair de onde está decidindo. Numa turma de quatro, responder "quem ainda não foi avisado?"
 * era comparar a lista de participantes com a lista de comunicação, separadas pelo painel inteiro
 * — duas listas das mesmas quatro pessoas, e nenhuma das duas respondendo sozinha.
 *
 * ## O botão segue o SERVIDOR
 *
 * Há botão exatamente quando o `Dispatch` aceitaria o disparo: sem `sem_envio` e sem trava de
 * repetição. Divergir faria a tela oferecer o que a API nega, ou esconder o que ela aceita — é a
 * mesma regra que `algumPodeReceber/1` aplica ao botão do rodapé, e ela é única de propósito.
 *
 * Esta função **substituiu** o antigo `podeReenviar/1`, que era mais estreito (só depois de uma
 * falha) porque governava um botão pendurado no histórico. Com a ação morando na linha da pessoa,
 * duas regras para "posso mandar?" na mesma tela seriam a divergência que este módulo passa o
 * tempo todo alertando contra.
 *
 * O rótulo muda com o histórico ("Enviar" na primeira vez, "Reenviar" depois) porque as duas
 * coisas são diferentes para quem clica, ainda que sejam o mesmo POST.
 *
 * ## A resposta do paciente ganha do estado da mensagem
 *
 * "Entregue" é um fato sobre o envio; "Confirmou presença" é um fato sobre a **sessão** — e é o
 * segundo que muda o que a recepção faz a seguir (§5). Por isso ele é o texto quando existe.
 */
export function comunicacaoDaPessoa(
	p: MessageParticipant,
	agora: string | number = Date.now()
): ComunicacaoDaPessoa {
	const bloqueio = p.sem_envio ?? travaDeRepeticao(p);
	const acao: ComunicacaoDaPessoa['acao'] = bloqueio
		? null
		: p.mensagens.length === 0
			? 'Enviar'
			: 'Reenviar';

	const base = {
		acao,
		bloqueio: bloqueio ? motivoTexto(bloqueio) : null
	};

	const ultima = p.mensagens[p.mensagens.length - 1];

	if (!ultima) {
		return {
			...base,
			// Com motivo, a frase JÁ diz "Nada enviado · <motivo>"; sem motivo, nada está errado e o
			// texto é o do §6 — o silêncio é uma linha, nunca ausência de linha.
			texto: semEnvioTexto(p.sem_envio) ?? SEM_COMUNICACAO,
			tone: 'faint',
			quando: null,
			previsao: false
		};
	}

	// A resposta pode ter vindo por qualquer mensagem (o link viaja em todas), então ela é
	// procurada na lista inteira — não só na última.
	const respondida = p.mensagens.find((m) => m.resposta);
	const previsto = previsaoDeEnvio(ultima, agora);

	return {
		...base,
		texto: respondida ? respostaTexto(respondida)! : textoDaMensagem(ultima),
		tone: respondida ? (respondida.resposta === 'confirmou' ? 'success' : 'muted') : tom(ultima),
		quando: previsto ?? instanteDoStatus(ultima),
		previsao: previsto !== null
	};
}

// "Confirmação por e-mail · Entregue", mais a explicação quando ela existe: o motivo em português
// da falha, ou a decisão que tirou a mensagem da fila. Sem elas, "Falhou" e "Não enviada" mandam a
// recepção procurar defeito sem dizer onde — ou onde não há nenhum.
function textoDaMensagem(m: Message): string {
	const cauda = m.erro_texto ?? descarteTexto(m);
	return `${tituloDaLinha(m)} · ${statusTexto(m)}${cauda ? ` · ${cauda}` : ''}`;
}

function tom(m: Message): ComunicacaoTom {
	if (m.status === 'falhou') return 'danger';
	if (m.status === 'entregue' || m.status === 'lido') return 'success';
	// Descartada não falou com ninguém: é o tom do silêncio, não o do sucesso.
	if (m.status === 'descartada') return 'faint';
	return 'muted';
}

/**
 * Alguém neste agendamento receberia alguma coisa se o "Enviar confirmação" do rodapé fosse
 * clicado agora?
 *
 * O botão do rodapé dispara para **todos** os participantes, então a pergunta dele não é a do
 * `podeReenviar` (que é por participante e também evita duplicar o que já saiu): aqui basta que
 * um único participante esteja desimpedido. Reenviar de propósito uma confirmação já entregue
 * continua valendo — o que não pode é o botão prometer envio quando a turma inteira está barrada
 * e o clique só devolve o mesmo motivo em forma de aviso.
 *
 * `null` é a timeline ainda carregando: não sabemos, e "não sei" não é "não dá" — o botão fica de
 * pé e o pior caso é o aviso que já existia.
 *
 * Quem está sob uma **trava de repetição** também não conta: o servidor recusa (`:ja_na_fila`,
 * `:ja_confirmou`, `:limite_de_envios`), e um botão que dispara para receber "nada enviado" de
 * volta é o mesmo botão que promete e não cumpre. A regra é a mesma dos dois lados de propósito —
 * divergir aqui faria a tela oferecer o que o `Dispatch` nega.
 */
export function algumPodeReceber(participantes: MessageParticipant[] | null): boolean {
	if (participantes === null) return true;

	return participantes.some((p) => !p.sem_envio && !travaDeRepeticao(p));
}

/**
 * Por que o "Enviar confirmação" está desabilitado — ou `null` quando ele pode disparar.
 *
 * Existe porque um botão desabilitado sem explicação faz a recepção clicar até desistir. Devolve a
 * frase **só quando todos os participantes estão barrados pelo MESMO motivo**: numa turma onde um
 * confirmou e outro não tem contato, qualquer frase única mentiria para um dos dois — e aí o
 * genérico ("o motivo está em Comunicação") é o honesto, porque a timeline mostra os dois linha a
 * linha.
 */
export function motivoDoBloqueio(participantes: MessageParticipant[] | null): string | null {
	if (participantes === null || participantes.length === 0) return null;
	if (algumPodeReceber(participantes)) return null;

	const motivos = new Set(participantes.map((p) => p.sem_envio ?? travaDeRepeticao(p)));

	return motivos.size === 1 ? motivoTexto([...motivos][0] as string) : null;
}

/**
 * A trava de repetição desta presença, ou `null` quando não há nenhuma.
 *
 * **Espelha o `barreira/3` do `Dispatch`, na mesma ordem** — e a ordem importa porque é ela que
 * escolhe a frase que a recepção lê: "já respondeu" encerra o assunto, "ainda está na fila" é
 * temporário, o teto é definitivo para esta sessão.
 */
function travaDeRepeticao(p: MessageParticipant): SemEnvio | null {
	if (p.mensagens.some((m) => m.resposta === 'confirmou')) return 'ja_confirmou';
	if (confirmacaoNaFila(p)) return 'ja_na_fila';
	if (confirmacoesEntregues(p) >= LIMITE_DE_CONFIRMACOES) return 'limite_de_envios';

	return null;
}

// `kind` importa: a trava do servidor é por (presença, tipo). Um LEMBRETE parado na fila não
// impede uma confirmação de sair, e travar por ele aqui faria a tela ser mais restritiva que a
// regra — o tipo de divergência que ninguém percebe até alguém não conseguir mandar.
//
// **`resposta` é a exceção**, e por isso ela não está aqui: o link de resposta viaja em TODA
// mensagem (`SendJob.render/1`), então quem confirmou pelo lembrete confirmou — e um pedido de
// confirmação depois disso é cobrar quem já respondeu.
function confirmacaoNaFila(p: MessageParticipant): boolean {
	return p.mensagens.some((m) => m.kind === 'confirmacao' && m.status === 'pendente');
}

/**
 * Quantas confirmações desta presença **alcançaram ou vão alcançar** o paciente.
 *
 * `falhou` e `descartada` de fora: nenhuma das duas falou com ninguém, e contá-las travaria
 * justamente quem precisa reenviar — a recepção que acabou de corrigir o e-mail na ficha. Mesma
 * lista do `@alcancam_o_paciente` do `Dispatch`.
 */
function confirmacoesEntregues(p: MessageParticipant): number {
	return p.mensagens.filter(
		(m) => m.kind === 'confirmacao' && ALCANCAM_O_PACIENTE.includes(m.status)
	).length;
}

const ALCANCAM_O_PACIENTE: MessageStatus[] = ['pendente', 'enviado', 'entregue', 'lido'];
