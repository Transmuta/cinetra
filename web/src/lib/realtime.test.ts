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

		pushes: Array<[string, unknown]> = [];

		on(event: string, cb: (p: unknown) => void) {
			this.handlers[event] = cb;
		}

		push(event: string, payload: unknown) {
			this.pushes.push([event, payload]);
			return { receive: () => ({ receive: () => ({}) }) };
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
			// S2 (Onda 5): o token entra por `authToken` (subprotocolo), não por `params` (query
			// string). O tipo é o contrato — `params` some daqui de propósito.
			public opts: { authToken: () => string; params?: () => Record<string, unknown> }
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
	viewerNames,
	__fecharSocketsCompartilhados,
	type AgendaHandlers
} from './realtime';

const config = { origin: 'http://localhost:4010', token: 'tok-1', clinic_id: 'c1' };

function handlers(): AgendaHandlers & {
	appointments: unknown[];
	removed: string[];
	sinais: number;
	resyncs: number;
} {
	const h = {
		appointments: [] as unknown[],
		removed: [] as string[],
		sinais: 0,
		resyncs: 0,
		onAppointment(p: unknown) {
			h.appointments.push(p);
		},
		onSignal() {
			h.sinais += 1;
		},
		onRemove(id: string) {
			h.removed.push(id);
		},
		onResync() {
			h.resyncs += 1;
		}
	};
	return h as never;
}

beforeEach(() => {
	// O socket é COMPARTILHADO e mora em estado de módulo, que sobrevive entre casos: sem esta
	// limpeza um teste que não desliga deixaria o socket dele de pé, o caso seguinte o reusaria e
	// `FakeSocket.last` continuaria apontando para a conexão do anterior.
	__fecharSocketsCompartilhados();
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

	it('manda o token pelo authToken (subprotocolo), não pela query string', () => {
		connectAgenda(config, ['t'], handlers());
		expect(fake.FakeSocket.last!.opts.authToken()).toBe('tok-1');
	});

	// O S2 só fecha se a porta antiga fechar junto: enquanto o token seguisse nos `params`, ele
	// continuaria na URL do socket — e é a URL que aparece em log de proxy.
	it('NÃO manda o token nos params — é o que o S2 fecha', () => {
		connectAgenda(config, ['t'], handlers());
		const params = fake.FakeSocket.last!.opts.params?.();
		expect(JSON.stringify(params ?? {})).not.toContain('tok-1');
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

	// Bate-volta da Onda 3: o servidor passou a empurrar `participant_removed` (A2 etapa 3), e o
	// cliente não o escutava — quem estava com a turma aberta seguia vendo o participante que saiu.
	it('participant_removed também chega ao handler de bloco', () => {
		const h = handlers();
		connectAgenda(config, ['t'], h);

		fake.FakeSocket.last!.channels[0].emit('participant_removed', {
			appointment: { id: 'a3' },
			patients: [],
			actor: null
		});

		expect(h.appointments).toHaveLength(1);
	});

	it('o sinal do mês vai para onSignal, não para onAppointment', () => {
		const h = handlers();
		connectAgenda(config, ['t'], h);

		fake.FakeSocket.last!.channels[0].emit('agenda_changed', { day: '2026-07-20' });

		expect(h.sinais).toBe(1);
		expect(h.appointments).toHaveLength(0);
	});

	it('appointment_excluded vai para onRemove (só o id), não para onAppointment', () => {
		const h = handlers();
		connectAgenda(config, ['t'], h);

		fake.FakeSocket.last!.channels[0].emit('appointment_excluded', { appointment_id: 'a9' });

		expect(h.removed).toEqual(['a9']);
		// Não é bloco: não passa pelo caminho de patch.
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

	it('token novo entra no authToken da próxima tentativa', async () => {
		const refreshToken = vi.fn().mockResolvedValue('tok-2');
		connectAgenda(config, ['t'], handlers(), { refreshToken });

		const socket = fake.FakeSocket.last!;
		socket.errorHandler!();
		await vi.waitFor(() => expect(socket.opts.authToken()).toBe('tok-2'));
	});

	it('token que não renova mantém o antigo, em vez de mandar vazio', async () => {
		const refreshToken = vi.fn().mockResolvedValue(null);
		connectAgenda(config, ['t'], handlers(), { refreshToken });

		const socket = fake.FakeSocket.last!;
		socket.errorHandler!();
		await vi.waitFor(() => expect(refreshToken).toHaveBeenCalled());

		expect(socket.opts.authToken()).toBe('tok-1');
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
		await vi.waitFor(() => expect(socket.opts.authToken()).toBe('tok-2'));
	});

	it('close() sai do canal e fecha o socket', () => {
		const conexao = connectWaitlist(config, { onChange() {} });
		const socket = fake.FakeSocket.last!;

		conexao.close();

		expect(socket.channels[0].left).toBe(true);
		expect(socket.disconnected).toBe(true);
	});

	// doc 39: o aviso "alguém está oferecendo" é presença. O cliente manda só o ID do item — o
	// nome vem do servidor —, e o que ele recebe de volta já chega sem ele mesmo.
	describe('presença de oferta', () => {
		it('offering/stoppedOffering empurram só o entry_id', () => {
			const conexao = connectWaitlist(config, { onChange() {} });
			const canal = fake.FakeSocket.last!.channels[0];

			conexao.offering('e1');
			conexao.stoppedOffering('e1');

			expect(canal.pushes).toEqual([
				['offering', { entry_id: 'e1' }],
				['stopped_offering', { entry_id: 'e1' }]
			]);
		});

		it('o presence_state vira entry_id → nomes, sem o próprio usuário', () => {
			let visto: Record<string, string[]> = {};
			connectWaitlist(
				config,
				{ onChange() {}, onOfferingChange: (m) => (visto = m) },
				{ userId: 'u-eu' }
			);

			fake.FakeSocket.last!.channels[0].emit('presence_state', {
				e1: { metas: [{ user_id: 'u-outra', nome: 'Ana Lima', phx_ref: 'r1' }] },
				e2: { metas: [{ user_id: 'u-eu', nome: 'Eu Mesmo', phx_ref: 'r2' }] }
			});

			expect(visto).toEqual({ e1: ['Ana Lima'] });
		});

		it('o diff aplica entradas e saídas', () => {
			let visto: Record<string, string[]> = {};
			connectWaitlist(
				config,
				{ onChange() {}, onOfferingChange: (m) => (visto = m) },
				{ userId: 'u-eu' }
			);

			const canal = fake.FakeSocket.last!.channels[0];

			canal.emit('presence_diff', {
				joins: { e1: { metas: [{ user_id: 'u-outra', nome: 'Ana Lima', phx_ref: 'r1' }] } }
			});
			expect(visto).toEqual({ e1: ['Ana Lima'] });

			canal.emit('presence_diff', {
				leaves: { e1: { metas: [{ user_id: 'u-outra', nome: 'Ana Lima', phx_ref: 'r1' }] } }
			});
			expect(visto).toEqual({});
		});
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
		await vi.waitFor(() => expect(socket.opts.authToken()).toBe('tok-2'));
	});

	it('a função de desligar sai do canal e fecha o socket', () => {
		const desligar = connectNotifications(config, { onNotification() {} });
		const socket = fake.FakeSocket.last!;

		desligar();

		expect(socket.channels[0].left).toBe(true);
		expect(socket.disconnected).toBe(true);
	});
});

// B7 (doc 101 §4.2) — o layout mantém as notificações abertas em TODA tela; a agenda e a fila
// abrem a delas por cima. Eram dois WebSockets por aba para a mesma clínica e o mesmo usuário.
describe('um socket por aba, N canais', () => {
	it('agenda e notificações dividem o mesmo socket', () => {
		connectNotifications(config, { onNotification() {} });
		const socket = fake.FakeSocket.last!;

		connectAgenda(config, ['clinic:c1:agenda:2026-07-20'], handlers());

		// Nenhum socket novo foi construído — o fake registra `last` no construtor.
		expect(fake.FakeSocket.last).toBe(socket);
		expect(socket.channels.map((c) => c.topic)).toEqual([
			'notifications:c1',
			'clinic:c1:agenda:2026-07-20'
		]);
	});

	it('a fila também entra no socket do layout', () => {
		connectNotifications(config, { onNotification() {} });
		const socket = fake.FakeSocket.last!;

		connectWaitlist(config, { onChange() {} });

		expect(fake.FakeSocket.last).toBe(socket);
		expect(socket.channels.length).toBe(2);
	});

	// A parte que um refcount errado quebra em silêncio: sair da agenda derrubaria o sino.
	it('fechar um cliente sai do canal dele e NÃO derruba o socket do outro', () => {
		const desligarNotif = connectNotifications(config, { onNotification() {} });
		const socket = fake.FakeSocket.last!;
		const desligarAgenda = connectAgenda(config, ['clinic:c1:agenda:2026-07-20'], handlers());

		desligarAgenda();

		expect(socket.channels[1].left).toBe(true);
		expect(socket.channels[0].left).toBe(false);
		expect(socket.disconnected).toBe(false);

		desligarNotif();

		expect(socket.disconnected).toBe(true);
	});

	it('desligar duas vezes não derruba o socket de quem ficou', () => {
		const desligarAgenda = connectAgenda(config, ['t1'], handlers());
		const socket = fake.FakeSocket.last!;
		connectNotifications(config, { onNotification() {} });

		desligarAgenda();
		desligarAgenda();

		expect(socket.disconnected).toBe(false);
	});

	it('depois que o último sai, o próximo cliente abre um socket NOVO', () => {
		const desligar = connectAgenda(config, ['t1'], handlers());
		const primeiro = fake.FakeSocket.last!;

		desligar();
		connectNotifications(config, { onNotification() {} });

		expect(fake.FakeSocket.last).not.toBe(primeiro);
		expect(fake.FakeSocket.last!.disconnected).toBe(false);
	});
});

// F5 — "quem está vendo este dia" (doc 30 / 09 §7.4).
describe('viewerNames', () => {
	it('lista os OUTROS que estão no dia, sem repetir quem tem duas abas', () => {
		const nomes = viewerNames(
			{
				'u-ana': {
					metas: [
						{ user_id: 'u-ana', nome: 'Ana Lima', phx_ref: 'r1' },
						{ user_id: 'u-ana', nome: 'Ana Lima', phx_ref: 'r2' }
					]
				},
				'u-bia': { metas: [{ user_id: 'u-bia', nome: 'Bia Reis', phx_ref: 'r3' }] }
			},
			'u-eu'
		);

		expect(nomes).toEqual(['Ana Lima', 'Bia Reis']);
	});

	it('tira o próprio usuário — o aviso é sobre os outros', () => {
		const nomes = viewerNames(
			{ 'u-eu': { metas: [{ user_id: 'u-eu', nome: 'Eu Mesmo', phx_ref: 'r1' }] } },
			'u-eu'
		);

		expect(nomes).toEqual([]);
	});

	it('meta sem nome não vira entrada vazia na tela', () => {
		const nomes = viewerNames({ 'u-x': { metas: [{ user_id: 'u-x', phx_ref: 'r1' }] } }, 'u-eu');
		expect(nomes).toEqual([]);
	});
});

describe('connectAgenda — presença do dia (F5)', () => {
	it('o presence_state vira a lista de quem mais está no dia', () => {
		let vistos: string[] = [];
		const h = handlers();

		connectAgenda(
			config,
			['clinic:c1:agenda:2026-07-20'],
			{ ...h, onViewers: (nomes: string[]) => (vistos = nomes) },
			{ userId: 'u-eu' }
		);

		fake.FakeSocket.last!.channels[0].emit('presence_state', {
			'u-ana': { metas: [{ user_id: 'u-ana', nome: 'Ana Lima', phx_ref: 'r1' }] },
			'u-eu': { metas: [{ user_id: 'u-eu', nome: 'Eu Mesmo', phx_ref: 'r2' }] }
		});

		expect(vistos).toEqual(['Ana Lima']);
	});

	it('sair some da lista', () => {
		let vistos: string[] = [];
		const h = handlers();

		connectAgenda(
			config,
			['clinic:c1:agenda:2026-07-20'],
			{ ...h, onViewers: (nomes: string[]) => (vistos = nomes) },
			{ userId: 'u-eu' }
		);

		const canal = fake.FakeSocket.last!.channels[0];

		canal.emit('presence_diff', {
			joins: { 'u-ana': { metas: [{ user_id: 'u-ana', nome: 'Ana Lima', phx_ref: 'r1' }] } }
		});
		expect(vistos).toEqual(['Ana Lima']);

		canal.emit('presence_diff', {
			leaves: { 'u-ana': { metas: [{ user_id: 'u-ana', nome: 'Ana Lima', phx_ref: 'r1' }] } }
		});
		expect(vistos).toEqual([]);
	});
});
