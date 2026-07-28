// Tipos e rótulos da comunicação com o paciente (doc 52 §6) — o vocabulário que a timeline do
// drawer usa. Vive fora do componente porque o BFF, a página e os testes falam dele.

/** Por que nada foi enviado. Os três do §6, na forma que a API devolve. */
export type SemEnvio = 'sem_consentimento' | 'sem_contato' | 'opt_out';

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

// O texto de cada silêncio. **Cada um leva uma ação diferente da recepção**, e é por isso que os
// três não colapsam num "não enviado": autorizar é abrir a ficha, contato é preencher um campo,
// e opt-out é uma conversa com o paciente — não algo que se conserte na tela.
const SEM_ENVIO_TEXTO: Record<SemEnvio, string> = {
	sem_consentimento: 'Nada enviado · sem consentimento de comunicação na ficha',
	sem_contato: 'Nada enviado · sem e-mail nem telefone cadastrado',
	opt_out: 'Nada enviado · o paciente pediu para não receber'
};

export function semEnvioTexto(motivo: SemEnvio | null): string | null {
	return motivo ? SEM_ENVIO_TEXTO[motivo] : null;
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
 * Sim quando não há mensagem nenhuma **e o motivo não é opt-out** (§10.4: quem pediu para parar
 * não recebe por insistência de botão), ou quando a última tentativa falhou. Uma mensagem em
 * trânsito ou já entregue não precisa de reenvio — e oferecê-lo convida a recepção a duplicar
 * comunicação com o paciente.
 */
export function podeReenviar(p: MessageParticipant): boolean {
	if (p.mensagens.length === 0) return p.semEnvio !== 'opt_out';

	const ultima = p.mensagens[p.mensagens.length - 1];
	return ultima.status === 'falhou';
}
