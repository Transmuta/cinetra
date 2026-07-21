import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchAudit: vi.fn() }));
vi.mock('$lib/server/audit', () => m);

import { load } from './+page.server';

// O load chama error() (que lança) nos ramos de falha; no sucesso a forma é concreta.
type LoadOk = {
	entries: unknown[];
	pageInfo: { total: number; more: boolean };
	resource: string;
	action: string | null;
	recordId: string | null;
	current: number;
};

function ev(search = ''): never {
	return { url: new URL(`http://x/configuracoes/auditoria${search}`) } as never;
}

const okData = {
	status: 200,
	data: { entries: [{ id: 'v1' }], page: { limit: 50, offset: 0, total: 1, more: false } }
};

beforeEach(() => m.fetchAudit.mockReset());

describe('load', () => {
	it('200 → entradas + meta, resource default appointment, página 1', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		const r = (await load(ev())) as LoadOk;
		expect(r.entries).toHaveLength(1);
		expect(r.resource).toBe('appointment');
		expect(r.current).toBe(1);
		expect(r.pageInfo.total).toBe(1);
	});

	it('traduz ?page= em offset e repassa resource/record_id', async () => {
		m.fetchAudit.mockResolvedValueOnce(okData);

		await load(ev('?resource=attendance&page=3&record_id=a1'));

		const [, params] = m.fetchAudit.mock.calls[0];
		expect(params).toMatchObject({
			resource: 'attendance',
			record_id: 'a1',
			limit: 50,
			offset: 100 // (3 - 1) * 50
		});
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
