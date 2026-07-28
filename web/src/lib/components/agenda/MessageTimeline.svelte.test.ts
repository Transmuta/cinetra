import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import MessageTimeline from './MessageTimeline.svelte';
import type { Message, MessageParticipant } from '$lib/messages';

// A timeline (doc 52 §6). O que precisa estar provado aqui é o **silêncio explicado**: quem não
// recebeu nada aparece com o motivo. Silêncio na tela faz a recepção supor que a mensagem saiu, e
// isso é pior do que não ter a funcionalidade.

const msg = (over: Partial<Message> = {}): Message => ({
	id: 'm1',
	canal: 'email',
	kind: 'confirmacao',
	status: 'entregue',
	destino: 'ana@example.com',
	erro: null,
	erroTexto: null,
	resposta: null,
	automatico: true,
	enfileiradoEm: '2026-08-10T12:00:00Z',
	enviadoEm: '2026-08-10T12:00:05Z',
	entregueEm: '2026-08-10T12:00:30Z',
	lidoEm: null,
	falhouEm: null,
	respondidoEm: null,
	titulo: 'Clínica: sua sessão',
	...over
});

const p = (over: Partial<MessageParticipant> = {}): MessageParticipant => ({
	attendanceId: 'a1',
	patientId: 'p1',
	paciente: 'Ana Souza',
	mensagens: [msg()],
	semEnvio: null,
	...over
});

const props = (over: Record<string, unknown> = {}) => ({
	participantes: [p()],
	timezone: 'America/Sao_Paulo',
	...over
});

afterEach(cleanup);

describe('MessageTimeline', () => {
	it('mostra a mensagem com estado e origem', () => {
		render(MessageTimeline, props());

		expect(screen.getByText(/Confirmação por e-mail/)).toBeInTheDocument();
		expect(screen.getByText('Entregue')).toBeInTheDocument();
		expect(screen.getByText(/automático/)).toBeInTheDocument();
	});

	it('carregando não mostra "nada a mostrar"', () => {
		// Piscar o vazio antes da resposta faria a recepção achar que não há comunicação.
		render(MessageTimeline, props({ carregando: true }));

		expect(screen.getByText('Carregando…')).toBeInTheDocument();
		expect(screen.queryByText(/Confirmação/)).not.toBeInTheDocument();
	});

	it('explica o silêncio em vez de omitir a linha', () => {
		render(MessageTimeline, props({ participantes: [p({ mensagens: [], semEnvio: 'sem_contato' })] }));

		expect(screen.getByText(/sem e-mail nem telefone/)).toBeInTheDocument();
	});

	it('destaca a resposta do paciente', () => {
		render(
			MessageTimeline,
			props({ participantes: [p({ mensagens: [msg({ resposta: 'confirmou', respondidoEm: '2026-08-10T18:41:00Z' })] })] })
		);

		expect(screen.getByText(/Confirmou presença/)).toBeInTheDocument();
	});

	it('mostra o motivo da falha', () => {
		render(
			MessageTimeline,
			props({
				participantes: [
					p({
						mensagens: [
							msg({
								status: 'falhou',
								erro: 'mailbox does not exist',
								erroTexto: 'E-mail não existe — confira o endereço na ficha'
							})
						]
					})
				]
			})
		);

		// O que a recepção lê é a ação em português; o cru do provider fica só para o suporte.
		expect(screen.getByText(/confira o endereço na ficha/)).toBeInTheDocument();
		expect(screen.queryByText(/mailbox does not exist/)).not.toBeInTheDocument();
	});

	it('só nomeia o participante quando há mais de um', () => {
		render(MessageTimeline, props());
		expect(screen.queryByText('Ana Souza')).not.toBeInTheDocument();

		cleanup();

		render(
			MessageTimeline,
			props({ participantes: [p(), p({ attendanceId: 'a2', patientId: 'p2', paciente: 'João Lima' })] })
		);
		expect(screen.getByText('Ana Souza')).toBeInTheDocument();
		expect(screen.getByText('João Lima')).toBeInTheDocument();
	});

	describe('reenviar', () => {
		it('não aparece sem permissão de escrita', () => {
			render(
				MessageTimeline,
				props({ participantes: [p({ mensagens: [], semEnvio: 'sem_contato' })], podeEnviar: false })
			);

			expect(screen.queryByRole('button')).not.toBeInTheDocument();
		});

		it('chama o handler com o participante certo', async () => {
			const onReenviar = vi.fn();
			render(
				MessageTimeline,
				props({
					participantes: [p({ mensagens: [msg({ status: 'falhou' })] })],
					podeEnviar: true,
					onReenviar
				})
			);

			await userEvent.click(screen.getByRole('button', { name: 'Reenviar' }));

			expect(onReenviar).toHaveBeenCalledWith('p1');
		});

		it('NÃO oferece reenvio a quem pediu para parar (§10.4)', async () => {
			render(
				MessageTimeline,
				props({
					participantes: [p({ mensagens: [], semEnvio: 'opt_out' })],
					podeEnviar: true,
					onReenviar: vi.fn()
				})
			);

			expect(screen.getByText(/pediu para não receber/)).toBeInTheDocument();
			expect(screen.queryByRole('button')).not.toBeInTheDocument();
		});

		it('diz "Enviar agora" quando nunca saiu nada', () => {
			render(
				MessageTimeline,
				props({
					participantes: [p({ mensagens: [], semEnvio: 'sem_contato' })],
					podeEnviar: true,
					onReenviar: vi.fn()
				})
			);

			expect(screen.getByRole('button', { name: 'Enviar agora' })).toBeInTheDocument();
		});
	});
});
