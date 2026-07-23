import { describe, it, expect, vi, beforeEach } from 'vitest';

// Fake do pacote `phoenix`: guarda os tópicos, os handlers e o `params`, para o teste
// observar o que o cliente pediu sem subir socket nenhum.
const fake = vi.hoisted(() => {
	class FakeChannel {
		handlers: Record<string, (p: unknown) => void> = {};
		joinCallbacks: Array<() => void> = [];
		left = false;

		constructor(
			public topic: string,
			public params: Record<string, unknown> = {}
		) {}

		on(event: string, cb: (p: unknown) => void) {
			this.handlers[event] = cb;
		}

		join() {
			return {
				receive: (status: string, cb: () => void) => {
					if (status === 'ok') this.joinCallbacks.push(cb);
					return { receive: () => ({}) };
				}
			};
		}

		leave() {
			this.left = true;
		}

		/** Simula o servidor empurrando um evento. */
		emit(event: string, payload: unknown) {
			this.handlers[event]?.(payload);
		}

		/** Simula o `ok` do join (o primeiro é entrada; os seguintes são rejoin). */
		acceptJoin() {
			for (const cb of this.joinCallbacks) cb();
		}
	}

	class FakeSocket {
		static last: FakeSocket | null = null;
		channels: FakeChannel[] = [];
		connected = false;
		disconnected = false;
		errorHandler: (() => void) | null = null;

		constructor(
			public url: string,
			public opts: { params: () => { token: string } }
		) {
			FakeSocket.last = this;
		}

		connect() {
			this.connected = true;
		}

		disconnect() {
			this.disconnected = true;
		}

		onError(cb: () => void) {
			this.errorHandler = cb;
		}

		channel(topic: string, params: Record<string, unknown> = {}) {
			const ch = new FakeChannel(topic, params);
			this.channels.push(ch);
			return ch;
		}
	}

	return { FakeSocket, FakeChannel };
});

vi.mock('phoenix', () => ({ Socket: fake.FakeSocket }));

import {
	socketUrl,
	agendaTopics,
	connectAgenda,
	connectWaitlist,
	connectNotifications,
	type AgendaHandlers
} from './realtime';

const config = { origin: 'http://localhost:4010', token: 'tok-1', clinic_id: 'c1' };

function handlers(): AgendaHandlers & {
	appointments: unknown[];
	sinais: number;
	resyncs: number;
} {
	const h = {
		appointments: [] as unknown[],
		sinais: 0,
		resyncs: 0,
		onAppointment(p: unknown) {
			h.appointments.push(p);
		},
		onSignal() {
			h.sinais += 1;
		},
		onResync() {
			h.resyncs += 1;
		}
	};
	return h as never;
}

beforeEach(() => {
	fake.FakeSocket.last = null;
});

describe('socketUrl', () => {
	it('http vira ws e https vira wss', () => {
		expect(socketUrl('http://localhost:4010')).toBe('ws://localhost:4010/socket');
		expect(socketUrl('https://api.exemplo.com')).toBe('wss://api.exemplo.com/socket');
	});

	it('tolera barra no fim', () => {
		expect(socketUrl('https://api.exemplo.com/')).toBe('wss://api.exemplo.com/socket');
	});
});

describe('agendaTopics', () => {
	it('Dia e Lista assinam um tópico de dia', () => {
		expect(agendaTopics('c1', 'dia', '2026-07-20')).toEqual(['clinic:c1:agenda:2026-07-20']);
		expect(agendaTopics('c1', 'lista', '2026-07-20')).toEqual(['clinic:c1:agenda:2026-07-20']);
	});

	it('Mês assina UM tópico de mês, não 31 de dia', () => {
		expect(agendaTopics('c1', 'mes', '2026-07-20')).toEqual(['clinic:c1:agenda:month:2026-07']);
	});

	it('Semana assina os 7 dias visíveis — e não o mês, porque a semana atravessa a virada', () => {
		const topics = agendaTopics('c1', 'semana', '2026-08-01');

		expect(topics).toHaveLength(7);
		// 2026-08-01 é sábado; a semana do projeto é segunda→domingo (A-D11), então ela começa
		// em 27 de JULHO e termina em 2 de agosto: dois meses, um tópico de mês não cobriria.
		expect(topics[0]).toBe('clinic:c1:agenda:2026-07-27');
		expect(topics[6]).toBe('clinic:c1:agenda:2026-08-02');
	});

	it('sem clínica ou sem data não assina nada', () => {
		expect(agendaTopics('', 'dia', '2026-07-20')).toEqual([]);
		expect(agendaTopics('c1', 'dia', '')).toEqual([]);
	});
});

describe('connectAgenda', () => {
	it('conecta na origem certa e entra em todos os tópicos', () => {
		connectAgenda(config, ['clinic:c1:agenda:2026-07-20'], handlers());
		const socket = fake.FakeSocket.last!;

		expect(socket.url).toBe('ws://localhost:4010/socket');
		expect(socket.connected).toBe(true);
		expect(socket.channels.map((c) => c.topic)).toEqual(['clinic:c1:agenda:2026-07-20']);
	});

	it('manda o token nos params', () => {
		connectAgenda(config, ['t'], handlers());
		expect(fake.FakeSocket.last!.opts.params()).toEqual({ token: 'tok-1' });
	});

	// D-G/D-H: o modo do join é o que evita o servidor reler o bloco para quem só desenha
	// contagem. O default é `block` — quem não pede nada continua recebendo o bloco.
	it('entra em modo block por padrão', () => {
		connectAgenda(config, ['t'], handlers());
		expect(fake.FakeSocket.last!.channels[0].params).toEqual({ mode: 'block' });
	});

	it('Semana e Mês entram em modo signal', () => {
		connectAgenda(config, ['t'], handlers(), { mode: 'signal' });
		expect(fake.FakeSocket.last!.channels[0].params).toEqual({ mode: 'signal' });
	});

	it('entrega os eventos de bloco ao handler', () => {
		const h = handlers();
		connectAgenda(config, ['t'], h);

		const canal = fake.FakeSocket.last!.channels[0];
		canal.emit('appointment_scheduled', { appointment: { id: 'a1' }, patients: [], actor: null });
		canal.emit('participant_added', { appointment: { id: 'a2' }, patients: [], actor: null });

		expect(h.appointments).toHaveLength(2);
	});

	it('o sinal do mês vai para onSignal, não para onAppointment', () => {
		const h = handlers();
		connectAgenda(config, ['t'], h);

		fake.FakeSocket.last!.channels[0].emit('agenda_changed', { day: '2026-07-20' });

		expect(h.sinais).toBe(1);
		expect(h.appointments).toHaveLength(0);
	});

	it('o PRIMEIRO join não ressincroniza; o rejoin sim', () => {
		// O primeiro join acontece logo depois do SSR — o estado já veio fresco na página, e
		// ressincronizar ali seria uma requisição desperdiçada em toda navegação.
		const h = handlers();
		connectAgenda(config, ['t'], h);

		const canal = fake.FakeSocket.last!.channels[0];
		canal.acceptJoin();
		expect(h.resyncs).toBe(0);

		canal.acceptJoin();
		expect(h.resyncs).toBe(1);
	});

	it('busca token novo quando o socket dá erro — a aba parada reconecta com token vencido', () => {
		const refreshToken = vi.fn().mockResolvedValue('tok-2');
		connectAgenda(config, ['t'], handlers(), { refreshToken });

		fake.FakeSocket.last!.errorHandler!();

		expect(refreshToken).toHaveBeenCalled();
	});

	it('token novo entra nos params da próxima tentativa', async () => {
		const refreshToken = vi.fn().mockResolvedValue('tok-2');
		connectAgenda(config, ['t'], handlers(), { refreshToken });

		const socket = fake.FakeSocket.last!;
		socket.errorHandler!();
		await vi.waitFor(() => expect(socket.opts.params()).toEqual({ token: 'tok-2' }));
	});

	it('token que não renova mantém o antigo, em vez de mandar vazio', async () => {
		const refreshToken = vi.fn().mockResolvedValue(null);
		connectAgenda(config, ['t'], handlers(), { refreshToken });

		const socket = fake.FakeSocket.last!;
		socket.errorHandler!();
		await vi.waitFor(() => expect(refreshToken).toHaveBeenCalled());

		expect(socket.opts.params()).toEqual({ token: 'tok-1' });
	});

	it('a função de desligar sai dos canais e fecha o socket', () => {
		const desligar = connectAgenda(config, ['t1', 't2'], handlers());
		const socket = fake.FakeSocket.last!;

		desligar();

		expect(socket.channels.every((c) => c.left)).toBe(true);
		expect(socket.disconnected).toBe(true);
	});
});

describe('connectWaitlist', () => {
	it('entra no tópico único da clínica', () => {
		connectWaitlist(config, { onChange() {} });
		const socket = fake.FakeSocket.last!;

		expect(socket.connected).toBe(true);
		expect(socket.channels.map((c) => c.topic)).toEqual(['waitlist:c1']);
	});

	it('o sinal waitlist_changed dispara onChange', () => {
		let mudancas = 0;
		connectWaitlist(config, { onChange: () => (mudancas += 1) });

		fake.FakeSocket.last!.channels[0].emit('waitlist_changed', { change: 'entry_upserted' });

		expect(mudancas).toBe(1);
	});

	it('o primeiro join não recarrega; o rejoin sim (pode ter perdido eventos)', () => {
		let mudancas = 0;
		connectWaitlist(config, { onChange: () => (mudancas += 1) });

		const canal = fake.FakeSocket.last!.channels[0];
		canal.acceptJoin();
		expect(mudancas).toBe(0);

		canal.acceptJoin();
		expect(mudancas).toBe(1);
	});

	it('renova o token quando o socket dá erro', async () => {
		const refreshToken = vi.fn().mockResolvedValue('tok-2');
		connectWaitlist(config, { onChange() {} }, { refreshToken });

		const socket = fake.FakeSocket.last!;
		socket.errorHandler!();
		await vi.waitFor(() => expect(socket.opts.params()).toEqual({ token: 'tok-2' }));
	});

	it('a função de desligar sai do canal e fecha o socket', () => {
		const desligar = connectWaitlist(config, { onChange() {} });
		const socket = fake.FakeSocket.last!;

		desligar();

		expect(socket.channels[0].left).toBe(true);
		expect(socket.disconnected).toBe(true);
	});
});

describe('connectNotifications', () => {
	it('entra no tópico da caixa do usuário na clínica', () => {
		connectNotifications(config, { onNotification() {} });
		const socket = fake.FakeSocket.last!;

		expect(socket.connected).toBe(true);
		expect(socket.channels.map((c) => c.topic)).toEqual(['notifications:c1']);
	});

	it('notification_created dispara onNotification', () => {
		let avisos = 0;
		connectNotifications(config, { onNotification: () => (avisos += 1) });

		fake.FakeSocket.last!.channels[0].emit('notification_created', { id: 'n1', title: 'Oi' });

		expect(avisos).toBe(1);
	});

	it('o primeiro join não avisa; o rejoin sim', () => {
		let avisos = 0;
		connectNotifications(config, { onNotification: () => (avisos += 1) });

		const canal = fake.FakeSocket.last!.channels[0];
		canal.acceptJoin();
		expect(avisos).toBe(0);

		canal.acceptJoin();
		expect(avisos).toBe(1);
	});

	it('renova o token quando o socket dá erro', async () => {
		const refreshToken = vi.fn().mockResolvedValue('tok-2');
		connectNotifications(config, { onNotification() {} }, { refreshToken });

		const socket = fake.FakeSocket.last!;
		socket.errorHandler!();
		await vi.waitFor(() => expect(socket.opts.params()).toEqual({ token: 'tok-2' }));
	});

	it('a função de desligar sai do canal e fecha o socket', () => {
		const desligar = connectNotifications(config, { onNotification() {} });
		const socket = fake.FakeSocket.last!;

		desligar();

		expect(socket.channels[0].left).toBe(true);
		expect(socket.disconnected).toBe(true);
	});
});
