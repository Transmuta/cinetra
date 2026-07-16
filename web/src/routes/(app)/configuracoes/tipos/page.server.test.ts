import { describe, it, expect, vi, beforeEach } from 'vitest';

// vi.hoisted: o factory de vi.mock é içado para o topo; sem isso, `m` estaria na TDZ.
const m = vi.hoisted(() => ({
	fetchAppointmentTypes: vi.fn(),
	createAppointmentType: vi.fn(),
	updateAppointmentType: vi.fn(),
	archiveAppointmentType: vi.fn(),
	restoreAppointmentType: vi.fn()
}));
vi.mock('$lib/server/appointment-types', () => m);

import { load, actions } from './+page.server';

// PageServerLoad inclui `void` no retorno (por causa do error, que retorna never); no caso
// de sucesso sabemos a forma concreta. Espelha o runLoad da tela de equipe.
type LoadOk = { appointmentTypes: unknown[]; capacidadePadrao: number };
const runLoad = async (): Promise<LoadOk> => (await load({} as never)) as LoadOk;

function ev(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

const campos = {
	nome: 'Sessão',
	duracao_minutos: '50',
	cor: '#0FB5A6',
	icon: 'Activity',
	grupo: 'false'
};

beforeEach(() => Object.values(m).forEach((fn) => fn.mockReset()));

describe('load', () => {
	it('200 → o catálogo inteiro, ativos e arquivados (a tela é que separa)', async () => {
		m.fetchAppointmentTypes.mockResolvedValueOnce({
			status: 200,
			data: {
				appointment_types: [
					{ id: 't1', ativo: true },
					{ id: 't2', ativo: false }
				],
				cap_turma_padrao: 4
			}
		});
		const r = await runLoad();
		expect(r.appointmentTypes).toHaveLength(2);
	});

	// T8: ler é de todo membro — diferente da tela de equipe, aqui NÃO há recorte de papel
	// no load. Só a escrita exige owner/admin.
	it('não recusa a leitura por papel — sem ramo 403 no load', async () => {
		m.fetchAppointmentTypes.mockResolvedValueOnce({
			status: 200,
			data: { appointment_types: [], cap_turma_padrao: 4 }
		});
		await expect(runLoad()).resolves.toBeTruthy();
	});

	it('sem data → error de gateway', async () => {
		m.fetchAppointmentTypes.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 502 });
	});

	// Cinto de segurança: se a API devolver um corpo malformado SEM o campo (o contrato manda
	// sempre mandá-lo, doc 20 §3), o load cai no DEFAULT_CAPACIDADE em vez de virar `undefined`
	// no modal. É defesa, não o contrato normal — daí o cast.
	it('resposta malformada (sem cap_turma_padrao) → cai no default defensivo', async () => {
		m.fetchAppointmentTypes.mockResolvedValueOnce({
			status: 200,
			data: { appointment_types: [] } as never
		});
		expect((await runLoad()).capacidadePadrao).toBe(4);
	});

	it('capacidade padrão usa cap_turma_padrao da clínica quando vier', async () => {
		m.fetchAppointmentTypes.mockResolvedValueOnce({
			status: 200,
			data: { appointment_types: [], cap_turma_padrao: 6 }
		});
		expect((await runLoad()).capacidadePadrao).toBe(6);
	});
});

describe('action save', () => {
	it('sem nome → fail 400 sem tocar na API (o Salvar já vem desabilitado)', async () => {
		const r = await actions.save(ev({ ...campos, nome: '  ' }));
		expect(r).toMatchObject({ status: 400 });
		expect(m.createAppointmentType).not.toHaveBeenCalled();
	});

	it('sem id → cria', async () => {
		m.createAppointmentType.mockResolvedValueOnce({ ok: true, status: 201 });
		const r = await actions.save(ev(campos));
		expect(r).toEqual({ action: 'save', ok: true });
		expect(m.createAppointmentType).toHaveBeenCalledWith(expect.anything(), {
			nome: 'Sessão',
			duracao_minutos: 50,
			cor: '#0FB5A6',
			icon: 'Activity',
			grupo: false,
			capacidade: null
		});
		expect(m.updateAppointmentType).not.toHaveBeenCalled();
	});

	it('com id → atualiza (mesma intenção, mesmo corpo — o id decide)', async () => {
		m.updateAppointmentType.mockResolvedValueOnce({ ok: true, status: 200 });
		const r = await actions.save(ev({ ...campos, id: 't1' }));
		expect(r).toEqual({ action: 'save', ok: true });
		expect(m.updateAppointmentType).toHaveBeenCalledWith(
			expect.anything(),
			't1',
			expect.objectContaining({ nome: 'Sessão' })
		);
		expect(m.createAppointmentType).not.toHaveBeenCalled();
	});

	it('grupo → manda a capacidade (present sse grupo, 01:474)', async () => {
		m.createAppointmentType.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.save(ev({ ...campos, grupo: 'true', capacidade: '8' }));
		expect(m.createAppointmentType).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ grupo: true, capacidade: 8 })
		);
	});

	it('não-grupo com capacidade no corpo → capacidade null, não o número órfão', async () => {
		m.createAppointmentType.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.save(ev({ ...campos, grupo: 'false', capacidade: '8' }));
		expect(m.createAppointmentType).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ grupo: false, capacidade: null })
		);
	});

	it('nome duplicado (422, T7) → fail com a mensagem da API', async () => {
		m.createAppointmentType.mockResolvedValueOnce({ ok: false, status: 422, error: 'ruim' });
		const r = await actions.save(ev(campos));
		expect(r).toMatchObject({ status: 422 });
	});
});

describe('actions archive / restore', () => {
	it('archive sem id → fail 400', async () => {
		const r = await actions.archive(ev({}));
		expect(r).toMatchObject({ status: 400 });
		expect(m.archiveAppointmentType).not.toHaveBeenCalled();
	});

	it('archive ok', async () => {
		m.archiveAppointmentType.mockResolvedValueOnce({ ok: true, status: 200 });
		expect(await actions.archive(ev({ id: 't1' }))).toEqual({ action: 'archive', ok: true });
		expect(m.archiveAppointmentType).toHaveBeenCalledWith(expect.anything(), 't1');
	});

	it('archive falha → fail com o status da API', async () => {
		m.archiveAppointmentType.mockResolvedValueOnce({ ok: false, status: 403, error: 'nope' });
		expect(await actions.archive(ev({ id: 't1' }))).toMatchObject({ status: 403 });
	});

	it('restore ok', async () => {
		m.restoreAppointmentType.mockResolvedValueOnce({ ok: true, status: 200 });
		expect(await actions.restore(ev({ id: 't1' }))).toEqual({ action: 'restore', ok: true });
		expect(m.restoreAppointmentType).toHaveBeenCalledWith(expect.anything(), 't1');
	});

	it('restore sem id → fail 400', async () => {
		expect(await actions.restore(ev({}))).toMatchObject({ status: 400 });
	});
});
