import { describe, it, expect, vi, beforeEach } from 'vitest';

const s = vi.hoisted(() => ({ fetchClinic: vi.fn(), updateClinicMessaging: vi.fn() }));
vi.mock('$lib/server/clinics', () => s);

import { load, actions } from './+page.server';

// A tela de comunicação (doc 52 §7). O que precisa estar preso aqui é a distinção
// **desligado ≠ zero**: mandar 0 em vez de `null` ligaria o lembrete para o instante da sessão.

const event = {} as never;

function formEvent(campos: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(campos)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

beforeEach(() => {
	s.fetchClinic.mockReset();
	s.updateClinicMessaging.mockReset();
	s.updateClinicMessaging.mockResolvedValue({ ok: true, status: 200 });
});

describe('load', () => {
	it('devolve a clínica', async () => {
		const clinic = { id: 'c1', msg_confirmacao_auto: true };
		s.fetchClinic.mockResolvedValueOnce({ status: 200, data: { clinic } });

		expect(await load(event)).toEqual({ clinic });
	});

	it('sem dado, levanta', async () => {
		s.fetchClinic.mockResolvedValueOnce({ status: 502, data: null });

		await expect(load(event)).rejects.toMatchObject({ status: 502 });
	});
});

describe('save', () => {
	it('lembrete em branco vira null — DESLIGADO, não zero', async () => {
		await actions.save(formEvent({ msg_confirmacao_auto: 'on', msg_lembrete_horas: '' }));

		expect(s.updateClinicMessaging.mock.calls[0][1]).toMatchObject({
			msg_confirmacao_auto: true,
			msg_lembrete_horas: null
		});
	});

	it('lembrete preenchido viaja como número', async () => {
		await actions.save(formEvent({ msg_lembrete_horas: '24' }));

		expect(s.updateClinicMessaging.mock.calls[0][1]).toMatchObject({ msg_lembrete_horas: 24 });
	});

	it('recusa hora fora da faixa antes de chamar a API', async () => {
		const out = (await actions.save(formEvent({ msg_lembrete_horas: '0' }))) as {
			status: number;
		};

		expect(out.status).toBe(400);
		expect(s.updateClinicMessaging).not.toHaveBeenCalled();
	});

	it('janela desligada manda as DUAS pontas em null', async () => {
		// Mandar só uma deixaria um estado meio-configurado que a tela não sabe desenhar.
		await actions.save(formEvent({ msg_silencio_inicio: '21', msg_silencio_fim: '8' }));

		expect(s.updateClinicMessaging.mock.calls[0][1]).toMatchObject({
			msg_silencio_inicio: null,
			msg_silencio_fim: null
		});
	});

	it('janela ligada manda as horas', async () => {
		await actions.save(
			formEvent({ silencio: 'on', msg_silencio_inicio: '22', msg_silencio_fim: '7' })
		);

		expect(s.updateClinicMessaging.mock.calls[0][1]).toMatchObject({
			msg_silencio_inicio: 22,
			msg_silencio_fim: 7
		});
	});

	it('confirmação desmarcada viaja como false', async () => {
		await actions.save(formEvent({}));

		expect(s.updateClinicMessaging.mock.calls[0][1]).toMatchObject({
			msg_confirmacao_auto: false
		});
	});

	it('erro da API vira mensagem na tela', async () => {
		s.updateClinicMessaging.mockResolvedValueOnce({ ok: false, status: 403, error: 'Sem permissão.' });

		const out = (await actions.save(formEvent({}))) as { status: number; data: { error: string } };

		expect(out.status).toBe(403);
		expect(out.data.error).toBe('Sem permissão.');
	});
});
