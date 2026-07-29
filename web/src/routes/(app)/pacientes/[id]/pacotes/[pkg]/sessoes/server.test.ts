import { describe, it, expect, vi, beforeEach } from 'vitest';

const srv = vi.hoisted(() => ({ fetchPackageSessions: vi.fn() }));
vi.mock('$lib/server/packages', () => srv);

import { GET } from './+server';

function ev(id: string, pkg: string) {
	return { params: { id, pkg } } as never;
}

beforeEach(() => srv.fetchPackageSessions.mockReset());

describe('GET /pacientes/[id]/pacotes/[pkg]/sessoes', () => {
	it('200 → a trilha, com o id do pacote vindo do PATH', async () => {
		const sessions = [{ attendance_id: 'a1', estado: 'proxima' }];
		srv.fetchPackageSessions.mockResolvedValueOnce({ status: 200, sessions });

		const res = await GET(ev('pac1', 'k1'));

		expect(srv.fetchPackageSessions.mock.calls[0][1]).toBe('k1');
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ sessions });
	});

	// 403/404 da API não viram 200 com lista vazia: a tela distingue "não tem sessão" de "não pode
	// ver", e é o aviso de erro que ela mostra no segundo caso.
	it('erro da API repassa o status, sem fingir lista vazia bem-sucedida', async () => {
		srv.fetchPackageSessions.mockResolvedValueOnce({ status: 403, sessions: [] });

		const res = await GET(ev('pac1', 'k1'));
		expect(res.status).toBe(403);
		expect(await res.json()).toEqual({ sessions: [] });
	});

	it('falha de conexão (status 0) devolve 200 com lista vazia — o modal mostra o vazio', async () => {
		srv.fetchPackageSessions.mockResolvedValueOnce({ status: 0, sessions: [] });

		const res = await GET(ev('pac1', 'k1'));
		expect(res.status).toBe(200);
	});
});
