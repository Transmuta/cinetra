import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchAudit: vi.fn(), fetchMembers: vi.fn() }));
vi.mock('$lib/server/audit', () => ({ fetchAudit: m.fetchAudit }));
vi.mock('$lib/server/members', () => ({ fetchMembers: m.fetchMembers }));

import { load } from './+page.server';

// O load chama error() (que lança) nos ramos de falha; no sucesso a forma é concreta.
type LoadOk = {
	entries: unknown[];
	pageInfo: { limit: number; offset: number; more: boolean };
	resource: string;
	action: string | null;
	period: string;
	autor: string | null;
	autores: { id: string; nome: string }[];
	hoje: string;
	recordId: string | null;
	current: number;
};

function ev(search = ''): never {
	return {
		url: new URL(`http://x/auditoria${search}`),
		parent: async () => ({ me: { timezone: 'America/Sao_Paulo' } })
	} as never;
}

const okData = {
	status: 200,
	data: { entries: [{ id: 'v1' }], page: { limit: 50, offset: 0, more: false } }
};

const okMembers = {
	status: 200,
	data: {
		members: [
			{ id: 'mem2', user_id: 'u2', nome: 'Bruno', email: 'b@x', papel: 'admin', status: 'ativo', professional_id: null },
			{ id: 'mem1', user_id: 'u1', nome: 'Ana', email: 'a@x', papel: 'owner', status: 'ativo', professional_id: null }
		],
		professionals: []
	}
};

beforeEach(() => {
	m.fetchAudit.mockReset();
	m.fetchMembers.mockReset();
	m.fetchMembers.mockResolvedValue(okMembers);
});

describe('load', () => {
	// Sem `?resource=`, o feed é da CLÍNICA INTEIRA (doc 63) — e é o default. Antes o default era
	// `appointment` e não havia como pedir "tudo": o recurso era o eixo que trocava a tabela lida.
	it('200 → entradas + meta, sem recorte de registro, página 1', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		const r = (await load(ev())) as LoadOk;
		expect(r.entries).toHaveLength(1);
		expect(r.resource).toBeNull();
		expect(r.period).toBe('tudo');
		expect(r.current).toBe(1);
		expect(r.pageInfo.more).toBe(false);
	});

	// O GRUPO da URL vira a lista de tipos que a API entende — a tradução que faz "Agenda" na
	// sidebar virar `appointment,attendance` no filtro.
	it('traduz ?page= em offset e o grupo nos tipos da API', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		await load(ev('?resource=agenda&page=3&record_id=a1'));

		const [, params] = m.fetchAudit.mock.calls[0];
		expect(params).toMatchObject({
			resource: 'appointment,attendance',
			record_id: 'a1',
			limit: 50,
			offset: 100 // (3 - 1) * 50
		});
	});

	it('grupo desconhecido não vira filtro (o feed é o da clínica)', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		const r = (await load(ev('?resource=lixo'))) as LoadOk;
		expect(r.resource).toBeNull();
		expect(m.fetchAudit.mock.calls[0][1].resource).toBeUndefined();
	});

	// O período viaja como PRESET na URL e vira janela `from`/`to` aqui — a API só entende datas,
	// e o teto dela é de menos de 31 dias.
	it('traduz ?periodo= em janela de datas locais', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		const r = (await load(ev('?periodo=7d'))) as LoadOk;
		const [, params] = m.fetchAudit.mock.calls[0];

		expect(r.period).toBe('7d');
		expect(params.to).toBe(r.hoje);
		expect(Date.parse(params.to) - Date.parse(params.from)).toBe(6 * 86400000);
	});

	it('"tudo" não manda janela (o caminho barato)', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		await load(ev());
		const [, params] = m.fetchAudit.mock.calls[0];
		expect(params.from).toBeUndefined();
		expect(params.to).toBeUndefined();
	});

	// A ação é validada CONTRA O GRUPO: `cancel` não é vocabulário de anexo, e o chip mentiria
	// sobre um recorte que não corresponde ao que está aberto.
	it('descarta ação que não é do grupo', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		const r = (await load(ev('?resource=anexos&acao=cancel'))) as LoadOk;
		expect(r.action).toBeNull();
		expect(m.fetchAudit.mock.calls[0][1].action).toBeUndefined();
	});

	it('o autor vira user_id na chamada da API', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		await load(ev('?autor=u1'));
		expect(m.fetchAudit.mock.calls[0][1].user_id).toBe('u1');
	});

	// `user_id` (o autor da versão), não `id` (o do vínculo) — filtrar pelo id errado devolveria
	// sempre lista vazia.
	it('a equipe alimenta o filtro por autor, ordenada por nome', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		const r = (await load(ev())) as LoadOk;
		expect(r.autores).toEqual([
			{ id: 'u1', nome: 'Ana' },
			{ id: 'u2', nome: 'Bruno' }
		]);
	});

	it('equipe indisponível não derruba o feed (perde-se o filtro, não a tela)', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);
		m.fetchMembers.mockRejectedValueOnce(new Error('api fora'));

		const r = (await load(ev())) as LoadOk;
		expect(r.entries).toHaveLength(1);
		expect(r.autores).toEqual([]);
	});

	it('403 da API vira página de erro (não lista vazia)', async () => {
		m.fetchAudit.mockResolvedValueOnce({ status: 403, data: null });
		await expect(load(ev())).rejects.toMatchObject({ status: 403 });
	});

	it('sem dados (API fora) → erro', async () => {
		m.fetchAudit.mockResolvedValueOnce({ status: 0, data: null });
		await expect(load(ev())).rejects.toBeTruthy();
	});
});
