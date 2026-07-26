// O cliente de tempo real da agenda (ADR-004, Entrega 3).
//
// É a única conexão do browser que NÃO passa pelo BFF (ADR-005): o WebSocket vai direto ao
// Phoenix, autenticado pelo token efêmero que o BFF busca em `/api/realtime/token`. Por isso
// a origem pública da API precisa descer até aqui, e por isso o `connect-src` da CSP tem de
// permiti-la (svelte.config.js).
import { Socket } from 'phoenix';
import { weekDays, type AgendaView } from './agenda-views';
import type { Appointment, AgendaPatient } from './agenda';

export interface RealtimeConfig {
	/** Origem pública da API (http/https) — o BFF a resolve de `API_PUBLIC_ORIGIN`. */
	origin: string;
	token: string;
	clinic_id: string;
}

export interface AgendaEventPayload {
	appointment: Appointment;
	patients: AgendaPatient[];
	actor: { id: string; nome: string } | null;
}

/**
 * O que esta conexão quer receber (D-G/D-H, doc 30 §4).
 *
 * `block` — o bloco serializado, para remendar o store (Dia e Lista).
 * `signal` — só "recarregue a contagem daquele dia" (Semana e Mês).
 *
 * Não é preferência de payload: é o que o **servidor** faz. No modo `signal` ele nem lê o
 * agendamento — antes, todo assinante pagava a releitura completa e a Semana/Mês a jogavam
 * fora, que é o desperdício que este parâmetro fecha.
 */
export type AgendaMode = 'block' | 'signal';

export interface AgendaHandlers {
	/** Dia e Lista: bloco cheio, aplicado como patch. */
	onAppointment(payload: AgendaEventPayload): void;
	/** Semana e Mês: sinal leve — recarrega as contagens da janela. */
	onSignal(): void;
	/**
	 * Dia e Lista: um bloco foi EXCLUÍDO (soft-delete, doc 40) — remove-o do store por id. Não é um
	 * `onAppointment` porque o bloco não vem mais (o servidor o esconde): o canal empurra só o id.
	 * Semana/Mês não usam — para elas a exclusão chega como `onSignal` (recarrega a contagem).
	 */
	onRemove(appointmentId: string): void;
	/** Rejoin depois de reconexão: o cliente pode ter perdido eventos (09 §7.5). */
	onResync(): void;
}

/**
 * Os eventos que carregam o bloco serializado (09 §7.2). Todos entram pelo mesmo `onAppointment`
 * e são aplicados como patch por `version` — o cliente casa pelo nome e ignora o que não conhece.
 * Os de ciclo de vida (Entrega 4) chegam com o bloco relido pelo canal; um `appointment_canceled`
 * traz o bloco já `cancelado`, e um `appointment_rescheduled` com o novo horário (o cliente
 * remove-o do dia se ele saiu dali).
 */
const EVENTOS_DE_BLOCO = [
	'appointment_scheduled',
	'participant_added',
	// A2 etapa 3: sair da turma também repinta o bloco — o canal relê e empurra o bloco já sem a
	// presença. Faltava aqui: o servidor emitia e ninguém escutava, então quem estava com a turma
	// aberta seguia vendo o participante que saiu até dar refresh (bate-volta da Onda 3).
	'participant_removed',
	'appointment_rescheduled',
	'appointment_status_changed',
	'appointment_canceled'
];

/** `http://x` → `ws://x/socket`; `https://x` → `wss://x/socket`. */
export function socketUrl(origin: string): string {
	return `${origin.replace(/\/+$/, '').replace(/^http/, 'ws')}/socket`;
}

/**
 * Os tópicos que cada visão assina (doc 04 §6.1).
 *
 * Dia e Lista assinam **um** tópico de dia e recebem o bloco cheio. Semana assina os 5–7 dias
 * visíveis — e não o tópico do mês, porque uma semana atravessa a virada de mês. Mês assina
 * **um** tópico de mês: 31 assinaturas para desenhar 31 barrinhas é o desenho que a resolução
 * dupla existe para evitar.
 */
export function agendaTopics(clinicId: string, view: AgendaView, date: string): string[] {
	if (!clinicId || !date) return [];

	if (view === 'mes') return [`clinic:${clinicId}:agenda:month:${date.slice(0, 7)}`];
	if (view === 'semana') return weekDays(date).map((d) => `clinic:${clinicId}:agenda:${d}`);

	return [`clinic:${clinicId}:agenda:${date}`];
}

/**
 * Abre o socket autenticado e liga a renovação de token. Os três clientes (agenda, fila e
 * notificações) montavam este mesmo bloco copiado; agora o S2 entra num lugar só.
 *
 * **Por onde o token viaja (S2, Onda 5).** Pelo `authToken`, que o Phoenix 1.8 manda no
 * subprotocolo `Sec-WebSocket-Protocol` — e não mais pelos `params`, que viram query string na
 * URL do socket e aparecem em log de proxy. O browser não deixa pôr header em WebSocket, então
 * a escolha real era entre esses dois. O servidor precisa do interruptor irmão
 * (`websocket: [auth_token: true]` no endpoint.ex): sem ele, isto aqui é ignorado.
 *
 * O token vive 15 minutos e o socket vive enquanto a aba estiver aberta, então `authToken` é uma
 * **função** — o Phoenix a reavalia a cada tentativa, e o `onError` troca o valor por um novo.
 */
function abrirSocket(config: RealtimeConfig, refreshToken: () => Promise<string | null>): Socket {
	let token = config.token;

	// O cast existe porque `@types/phoenix` (1.6.7) ainda tipa `authToken` como `string`, embora o
	// runtime aceite função desde a 1.8 (`opts.authToken && closure(opts.authToken)`). Passar a
	// string congelaria o token da primeira conexão e mataria a renovação que os testes cobrem.
	const socket = new Socket(socketUrl(config.origin), {
		authToken: (() => token) as unknown as string
	});

	socket.onError(() => {
		void refreshToken().then((novo) => {
			if (novo) token = novo;
		});
	});

	socket.connect();
	return socket;
}

/** Busca um token novo no BFF. Usado quando o socket cai e o token pode ter vencido. */
async function buscarToken(): Promise<string | null> {
	try {
		const res = await fetch('/api/realtime/token');
		if (!res.ok) return null;
		const body = (await res.json()) as { token?: string };
		return body.token ?? null;
	} catch {
		return null;
	}
}

/**
 * Abre o socket, entra nos tópicos e devolve a função de desligar.
 *
 * O token vive 15 minutos, mas o socket vive enquanto a aba estiver aberta. Uma aba parada a
 * tarde inteira reconecta com um token vencido e ficaria fora do ar em silêncio — por isso o
 * `params` é uma **função** (o Phoenix a reavalia a cada tentativa) e o `onError` busca um
 * token novo. É o único caminho de renovação: nada aqui renova por timer.
 */
export function connectAgenda(
	config: RealtimeConfig,
	topics: string[],
	handlers: AgendaHandlers,
	opts: { refreshToken?: () => Promise<string | null>; mode?: AgendaMode } = {}
): () => void {
	const refreshToken = opts.refreshToken ?? buscarToken;
	const mode = opts.mode ?? 'block';

	const socket = abrirSocket(config, refreshToken);

	const channels = topics.map((topic) => {
		const channel = socket.channel(topic, { mode });

		for (const evento of EVENTOS_DE_BLOCO) {
			channel.on(evento, (payload) => handlers.onAppointment(payload as AgendaEventPayload));
		}

		// Soft-delete (doc 40): não carrega bloco, só o id a remover (o servidor esconde o excluído,
		// então não há o que reler). Fora de `EVENTOS_DE_BLOCO` de propósito — aqueles esperam um
		// bloco cheio em `onAppointment`.
		channel.on('appointment_excluded', (payload) =>
			handlers.onRemove((payload as { appointment_id: string }).appointment_id)
		);

		channel.on('agenda_changed', () => handlers.onSignal());

		// O primeiro `ok` é a entrada normal, logo depois do SSR — o estado já está fresco.
		// Do segundo em diante é rejoin de reconexão, e aí o cliente NÃO assume store fresco:
		// pode ter perdido evento enquanto esteve fora (09 §7.5).
		let entrou = false;
		channel.join().receive('ok', () => {
			if (entrou) handlers.onResync();
			entrou = true;
		});

		return channel;
	});

	return () => {
		for (const channel of channels) channel.leave();
		socket.disconnect();
	};
}

export interface NotificationHandlers {
	/** Chegou uma notificação para este usuário (o Rail sobe o badge). */
	onNotification(): void;
}

/**
 * Conecta ao tópico da caixa deste usuário (`notifications:<clinic_id>`, doc 31 §5) e devolve a
 * função de desligar. Simples como a fila: o push é um sinal (`notification_created`) e o cliente
 * reage subindo o badge (e, se a tela `/notificacoes` estiver aberta, revalidando o load). A
 * renovação de token no `onError` é a mesma da agenda. O rejoin de reconexão também dispara
 * `onNotification` — pode ter chegado algo enquanto o socket esteve fora.
 */
export function connectNotifications(
	config: RealtimeConfig,
	handlers: NotificationHandlers,
	deps: { refreshToken?: () => Promise<string | null> } = {}
): () => void {
	const refreshToken = deps.refreshToken ?? buscarToken;

	const socket = abrirSocket(config, refreshToken);

	const channel = socket.channel(`notifications:${config.clinic_id}`, {});
	channel.on('notification_created', () => handlers.onNotification());

	let entrou = false;
	channel.join().receive('ok', () => {
		if (entrou) handlers.onNotification();
		entrou = true;
	});

	return () => {
		channel.leave();
		socket.disconnect();
	};
}

export interface WaitlistHandlers {
	/** Qualquer mutação na fila (entrada/edição/saída) OU um rejoin de reconexão. */
	onChange(): void;
	/**
	 * Quem está oferecendo o quê, agora (doc 39): `entry_id → [nomes]`, já **sem** o próprio
	 * usuário. Chega no join e a cada entrada/saída de alguém.
	 */
	onOfferingChange?(porEntrada: Record<string, string[]>): void;
}

/** O que a tela usa para anunciar (e parar de anunciar) que está oferecendo um item. */
export interface WaitlistConnection {
	/** Desliga o socket. */
	close(): void;
	/** "Estou oferecendo este item" — o modal abriu. */
	offering(entryId: string): void;
	/** "Parei" — o modal fechou. (Cair a aba também para, sozinho.) */
	stoppedOffering(entryId: string): void;
}

/** A forma que o Phoenix.Presence manda no `presence_state`/`presence_diff`. */
interface PresenceEntry {
	metas: Array<{ user_id?: string; nome?: string; phx_ref?: string }>;
}

type PresenceMap = Record<string, PresenceEntry>;

/**
 * Aplica um `presence_diff` sobre o estado local. É o mínimo do protocolo (o pacote `phoenix`
 * traz um `Presence` completo, com histórico de refs, que aqui seria peso sem uso: a fila só
 * quer saber **quem** está em cada item).
 */
export function applyPresenceDiff(
	atual: PresenceMap,
	diff: { joins?: PresenceMap; leaves?: PresenceMap }
): PresenceMap {
	const next: PresenceMap = { ...atual };

	for (const [key, entry] of Object.entries(diff.leaves ?? {})) {
		const saindo = new Set(entry.metas.map((m) => m.phx_ref));
		const restantes = (next[key]?.metas ?? []).filter((m) => !saindo.has(m.phx_ref));
		if (restantes.length) next[key] = { metas: restantes };
		else delete next[key];
	}

	for (const [key, entry] of Object.entries(diff.joins ?? {})) {
		next[key] = { metas: [...(next[key]?.metas ?? []), ...entry.metas] };
	}

	return next;
}

/**
 * `entry_id → nomes`, **tirando o próprio usuário**: a tela quer avisar sobre os OUTROS. Sem
 * isso, quem abre o modal veria "você está oferecendo" na própria linha.
 */
export function offeringNames(presencas: PresenceMap, meuId: string | null): Record<string, string[]> {
	const out: Record<string, string[]> = {};

	for (const [entryId, entry] of Object.entries(presencas)) {
		const nomes = entry.metas
			.filter((m) => m.user_id !== meuId)
			.map((m) => m.nome)
			.filter((n): n is string => !!n);

		if (nomes.length) out[entryId] = [...new Set(nomes)];
	}

	return out;
}

/**
 * Conecta ao tópico único da fila (`waitlist:<clinic_id>`, Entrega 5, D-E5.3) e devolve a função
 * de desligar. Muito mais simples que a agenda: a fila **não é recortada por papel**, então o
 * push é um **sinal** (`waitlist_changed`) e o cliente recarrega a lista inteira pelo REST — não
 * há bloco para remendar. A renovação de token no `onError` é a mesma da agenda (o socket vive
 * mais que o token de 15 min). O rejoin de reconexão também dispara `onChange` (pode ter perdido
 * eventos enquanto esteve fora).
 */
export function connectWaitlist(
	config: RealtimeConfig,
	handlers: WaitlistHandlers,
	deps: { refreshToken?: () => Promise<string | null>; userId?: string | null } = {}
): WaitlistConnection {
	const refreshToken = deps.refreshToken ?? buscarToken;
	const meuId = deps.userId ?? null;

	const socket = abrirSocket(config, refreshToken);

	const channel = socket.channel(`waitlist:${config.clinic_id}`, {});
	channel.on('waitlist_changed', () => handlers.onChange());

	// Presença (doc 39): quem está oferecendo qual item. Estado no join, diffs depois.
	let presencas: PresenceMap = {};

	const avisar = () => handlers.onOfferingChange?.(offeringNames(presencas, meuId));

	channel.on('presence_state', (estado) => {
		presencas = (estado ?? {}) as PresenceMap;
		avisar();
	});

	channel.on('presence_diff', (diff) => {
		presencas = applyPresenceDiff(presencas, (diff ?? {}) as { joins?: PresenceMap });
		avisar();
	});

	let entrou = false;
	channel.join().receive('ok', () => {
		if (entrou) handlers.onChange();
		entrou = true;
	});

	return {
		close() {
			channel.leave();
			socket.disconnect();
		},
		offering(entryId: string) {
			channel.push('offering', { entry_id: entryId });
		},
		stoppedOffering(entryId: string) {
			channel.push('stopped_offering', { entry_id: entryId });
		}
	};
}
