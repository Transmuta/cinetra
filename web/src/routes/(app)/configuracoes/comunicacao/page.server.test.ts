import { describe, it, expect, vi, beforeEach } from 'vitest';

const s = vi.hoisted(() => ({ fetchClinic: vi.fn(), updateClinicMessaging: vi.fn() }));
vi.mock('$lib/server/clinics', () => s);

import { load, actions } from './+page.server';

// A tela de comunicação (doc 52 §7). O lembrete — e com ele a distinção "desligado ≠ zero" que
// este arquivo guardava — saiu em 2026-08-01: sem cron, o número não tinha quem o lesse. O que
// restou de load-bearing é o interruptor de WhatsApp, e o que o torna DESLIGÁVEL: campo ausente
// significa `false`, não "não mexe".

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
		const clinic = { id: 'c1', msg_lembrete_horas: 2 };
		s.fetchClinic.mockResolvedValueOnce({ status: 200, data: { clinic } });

		expect(await load(event)).toEqual({ clinic });
	});

	it('sem dado, levanta', async () => {
		s.fetchClinic.mockResolvedValueOnce({ status: 502, data: null });

		await expect(load(event)).rejects.toMatchObject({ status: 502 });
	});
});

describe('save', () => {
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

	it('`whatsapp=on` liga o canal', async () => {
		await actions.save(formEvent({ whatsapp: 'on' }));

		expect(s.updateClinicMessaging.mock.calls[0][1]).toMatchObject({ msg_whatsapp_ativo: true });
	});

	it('`whatsapp` ausente DESLIGA — e é isso que torna o interruptor reversível', async () => {
		// Se ausente significasse "não mexe", o canal seria impossível de desligar pela tela. Aqui o
		// custo do engano não é uma configuração perdida como no doc 98 §6: é mensagem paga saindo
		// depois de a clínica ter pedido para parar.
		await actions.save(formEvent({}));

		expect(s.updateClinicMessaging.mock.calls[0][1]).toMatchObject({ msg_whatsapp_ativo: false });
	});

	it('não manda mais a confirmação automática — o campo deixou de existir (doc 98)', async () => {
		// A tela perdeu o controle e a API perdeu a coluna. Um payload que ainda carregasse a chave
		// seria recusado pela ação do Ash, e o sintoma na tela seria "não foi possível salvar" para
		// qualquer mudança de lembrete ou de silêncio.
		await actions.save(formEvent({ msg_confirmacao_auto: 'on' }));

		expect(s.updateClinicMessaging.mock.calls[0][1]).not.toHaveProperty('msg_confirmacao_auto');
	});

	it('erro da API vira mensagem na tela', async () => {
		s.updateClinicMessaging.mockResolvedValueOnce({ ok: false, status: 403, error: 'Sem permissão.' });

		const out = (await actions.save(formEvent({}))) as { status: number; data: { error: string } };

		expect(out.status).toBe(403);
		expect(out.data.error).toBe('Sem permissão.');
	});
});
