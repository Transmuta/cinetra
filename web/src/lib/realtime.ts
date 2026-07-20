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

export interface AgendaHandlers {
	/** Dia e Lista: bloco cheio, aplicado como patch. */
	onAppointment(payload: AgendaEventPayload): void;
	/** Semana e Mês: sinal leve — recarrega as contagens da janela. */
	onSignal(): void;
	/** Rejoin depois de reconexão: o cliente pode ter perdido eventos (09 §7.5). */
	onResync(): void;
}

/** Os eventos que carregam bloco (09 §7.2). Os de ciclo de vida entram na Entrega 4. */
const EVENTOS_DE_BLOCO = ['appointment_scheduled', 'participant_added'];

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
	deps: { refreshToken?: () => Promise<string | null> } = {}
): () => void {
	const refreshToken = deps.refreshToken ?? buscarToken;
	let token = config.token;

	const socket = new Socket(socketUrl(config.origin), { params: () => ({ token }) });

	socket.onError(() => {
		void refreshToken().then((novo) => {
			if (novo) token = novo;
		});
	});

	socket.connect();

	const channels = topics.map((topic) => {
		const channel = socket.channel(topic, {});

		for (const evento of EVENTOS_DE_BLOCO) {
			channel.on(evento, (payload) => handlers.onAppointment(payload as AgendaEventPayload));
		}

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
