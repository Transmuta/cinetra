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
	| 'opt_out'
	/**
	 * Já há uma mensagem deste tipo esperando na fila para esta presença.
	 *
	 * Só aparece na **resposta do disparo**, nunca como explicação de silêncio na timeline: lá o
	 * motivo só é calculado quando não existe mensagem nenhuma, e este significa o contrário.
	 */
	| 'ja_na_fila';

export type MessageStatus = 'pendente' | 'enviado' | 'entregue' | 'lido' | 'falhou' | 'descartada';

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
	erroTexto: string | null;
	resposta: 'confirmou' | 'quer_remarcar' | null;
	/** Nulo do lado da API = ninguém clicou. É o que distingue "automático" de "alguém mandou". */
	automatico: boolean;
	enfileiradoEm: string | null;
	/** Preenchido só quando a janela de silêncio adiou o envio — ver `previsaoDeEnvio`. */
	agendadoPara: string | null;
	enviadoEm: string | null;
	entregueEm: string | null;
	lidoEm: string | null;
	falhouEm: string | null;
	/** Preenchido só quando a mensagem foi retirada da fila — ver `descarteTexto`. */
	descartadaEm: string | null;
	descarteMotivo: DescarteMotivo | null;
	respondidoEm: string | null;
	titulo: string;
}

export interface MessageParticipant {
	attendanceId: string;
	patientId: string;
	paciente: string;
	mensagens: Message[];
	/** Preenchido só quando NÃO há mensagem nenhuma — ver `semEnvioTexto`. */
	semEnvio: SemEnvio | null;
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
	opt_out: 'o paciente pediu para não receber',
	// Este não pede ação nenhuma — pelo contrário, diz que a ação já foi tomada. Some do balcão a
	// impressão de que o clique falhou, que é o que faz a recepção clicar de novo.
	ja_na_fila: 'a mensagem anterior ainda está na fila para este paciente'
};

// O motivo cru vem da API: um átomo novo lá não pode virar `undefined` na tela.
function motivoTexto(motivo: string): string {
	return SEM_ENVIO_MOTIVO[motivo as SemEnvio] ?? 'não foi possível enviar';
}

export function semEnvioTexto(motivo: SemEnvio | null): string | null {
	return motivo ? `Nada enviado · ${motivoTexto(motivo)}` : null;
}

/** O que a API responde por participante no disparo manual (`POST .../messages`). */
export interface SendOutcome {
	patientId: string;
	enviado: boolean;
	motivo?: string | null;
	/** Aceita, mas adiada pela janela de silêncio (§7) — não saiu ainda. */
	agendadoPara?: string | null;
}

/**
 * O que dizer depois de clicar em "Enviar agora".
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
	const adiados = enviados.filter((r) => r.agendadoPara);

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
	return m.descarteMotivo ? (DESCARTE_TEXTO[m.descarteMotivo] ?? null) : null;
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
		m.descartadaEm ?? m.falhouEm ?? m.lidoEm ?? m.entregueEm ?? m.enviadoEm ?? m.enfileiradoEm
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
 * não o que se previa. E `agendadoPara` no passado não vira promessa — ali o job está atrasado ou
 * em retentativa, e "sai às 8h" às 9h seria a tela mentindo com precisão.
 */
export function previsaoDeEnvio(m: Message, agora: string | number = Date.now()): string | null {
	if (m.status !== 'pendente' || !m.agendadoPara) return null;

	return Date.parse(m.agendadoPara) > new Date(agora).getTime() ? m.agendadoPara : null;
}

const RESPOSTA_TEXTO: Record<NonNullable<Message['resposta']>, string> = {
	confirmou: 'Confirmou presença',
	quer_remarcar: 'Pediu para remarcar'
};

export function respostaTexto(m: Message): string | null {
	return m.resposta ? RESPOSTA_TEXTO[m.resposta] : null;
}

/**
 * O reenvio faz sentido para este participante?
 *
 * Sim quando não há mensagem nenhuma **e nada bloqueia o envio**, ou quando a última tentativa
 * falhou. Uma mensagem em trânsito ou já entregue não precisa de reenvio — e oferecê-lo convida a
 * recepção a duplicar comunicação com o paciente.
 *
 * `semEnvio` preenchido é exatamente o `{:skip, motivo}` do `Dispatch.avaliar/2` (o BFF só o
 * devolve quando não há mensagem): clicar ali dispara, a API responde 201 e o disparo é pulado
 * **pelo mesmo motivo** que a linha acima já explicou. Um botão que promete ação e devolve a
 * mesma frase manda a recepção insistir num lugar onde não há o que fazer — e, no
 * `canal_indisponivel`, o que falta nem é dela (é de quem opera a instalação). Ele reaparece
 * sozinho quando o motivo deixa de valer: a timeline é reavaliada a cada abertura do drawer.
 *
 * O `opt_out` era o único caso barrado aqui (§10.4) — continua barrado, agora pela regra geral.
 */
export function podeReenviar(p: MessageParticipant): boolean {
	if (p.mensagens.length === 0) return !p.semEnvio;

	const ultima = p.mensagens[p.mensagens.length - 1];
	return ultima.status === 'falhou';
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
 * Quem já tem uma **confirmação na fila** também não conta: o servidor recusa a duplicata
 * (`:ja_na_fila`), e um botão que dispara para receber "nada enviado" de volta é o mesmo botão
 * que promete e não cumpre. A regra é a mesma dos dois lados de propósito — divergir aqui faria a
 * tela oferecer o que o `Dispatch` nega.
 */
export function algumPodeReceber(participantes: MessageParticipant[] | null): boolean {
	if (participantes === null) return true;

	return participantes.some((p) => !p.semEnvio && !confirmacaoNaFila(p));
}

// `kind` importa: a trava do servidor é por (presença, tipo). Um LEMBRETE parado na fila não
// impede uma confirmação de sair, e travar por ele aqui faria a tela ser mais restritiva que a
// regra — o tipo de divergência que ninguém percebe até alguém não conseguir mandar.
function confirmacaoNaFila(p: MessageParticipant): boolean {
	return p.mensagens.some((m) => m.kind === 'confirmacao' && m.status === 'pendente');
}
