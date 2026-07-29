// Tipos e rótulos da comunicação com o paciente (doc 52 §6) — o vocabulário que a timeline do
// drawer usa. Vive fora do componente porque o BFF, a página e os testes falam dele.

/**
 * Por que nada foi enviado, na forma que a API devolve (`Api.Messaging.Dispatch`).
 *
 * `sem_contato` e `canal_indisponivel` já foram o mesmo motivo, e a fusão mentia no balcão:
 * paciente com celular na ficha lia "sem e-mail nem telefone cadastrado" quando o problema era o
 * WhatsApp desligado. Um manda a recepção preencher a ficha; o outro não é da recepção.
 */
export type SemEnvio = 'sem_consentimento' | 'sem_contato' | 'canal_indisponivel' | 'opt_out';

export type MessageStatus = 'pendente' | 'enviado' | 'entregue' | 'lido' | 'falhou';

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
	enviadoEm: string | null;
	entregueEm: string | null;
	lidoEm: string | null;
	falhouEm: string | null;
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
	opt_out: 'o paciente pediu para não receber'
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

	if (!pulado) {
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
	falhou: 'Falhou'
};

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
	return m.falhouEm ?? m.lidoEm ?? m.entregueEm ?? m.enviadoEm ?? m.enfileiradoEm;
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
 */
export function algumPodeReceber(participantes: MessageParticipant[] | null): boolean {
	if (participantes === null) return true;

	return participantes.some((p) => !p.semEnvio);
}
