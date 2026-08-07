import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import MessageTimeline from './MessageTimeline.svelte';
import { SEM_COMUNICACAO, type Message, type MessageParticipant } from '$lib/messages';

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
	erro_texto: null,
	resposta: null,
	automatico: true,
	enfileirado_em: '2026-08-10T12:00:00Z',
	agendado_para: null,
	enviado_em: '2026-08-10T12:00:05Z',
	entregue_em: '2026-08-10T12:00:30Z',
	lido_em: null,
	falhou_em: null,
	descartada_em: null,
	descarte_motivo: null,
	respondido_em: null,
	titulo: 'Clínica: sua sessão',
	...over
});

const p = (over: Partial<MessageParticipant> = {}): MessageParticipant => ({
	attendance_id: 'a1',
	patient_id: 'p1',
	paciente: 'Ana Souza',
	mensagens: [msg()],
	sem_envio: null,
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
		render(MessageTimeline, props({ participantes: [p({ mensagens: [], sem_envio: 'sem_contato' })] }));

		expect(screen.getByText(/sem e-mail nem telefone/)).toBeInTheDocument();
	});

	it('destaca a resposta do paciente', () => {
		render(
			MessageTimeline,
			props({ participantes: [p({ mensagens: [msg({ resposta: 'confirmou', respondido_em: '2026-08-10T18:41:00Z' })] })] })
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
								erro_texto: 'E-mail não existe — confira o endereço na ficha'
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

	it('mensagem adiada diz QUANDO sai, no fuso da clínica', () => {
		// O relato ao vivo: três confirmações corretamente adiadas pela janela de silêncio (§7), e
		// a tela mostrando "Na fila · ter 22:17" — o instante em que ela ENTROU na fila. A leitura
		// natural disso é "não está enviando", que foi exatamente a conclusão de quem testou.
		render(
			MessageTimeline,
			props({
				participantes: [
					p({
						mensagens: [
							msg({
								status: 'pendente',
								enviado_em: null,
								entregue_em: null,
								enfileirado_em: '2026-08-11T01:17:00Z',
								agendado_para: '2026-08-11T11:00:00Z'
							})
						]
					})
				],
				agora: '2026-08-11T01:20:00Z'
			})
		);

		// 11:00Z = 08:00 em São Paulo, o fim da janela.
		expect(screen.getByText(/sai .*08:00/)).toBeInTheDocument();
		// E o instante de entrada na fila sai de cena: ele não responde a pergunta de quem lê.
		expect(screen.queryByText(/22:17/)).not.toBeInTheDocument();
	});

	it('mensagem descartada para de prometer saída, e diz por quê', () => {
		// O outro lado do teste acima. A janela de silêncio abriu uma brecha de horas entre pedir e
		// enviar, e nela o bloco pode ser cancelado: a mensagem some da fila, mas a tela continuava
		// anunciando "sai qua., 08:00" para algo que não vai mais sair.
		render(
			MessageTimeline,
			props({
				participantes: [
					p({
						mensagens: [
							msg({
								status: 'descartada',
								enviado_em: null,
								entregue_em: null,
								agendado_para: '2026-08-11T11:00:00Z',
								descartada_em: '2026-08-11T01:45:00Z',
								descarte_motivo: 'sessao_cancelada'
							})
						]
					})
				],
				agora: '2026-08-11T01:50:00Z'
			})
		);

		expect(screen.queryByText(/sai /)).not.toBeInTheDocument();
		expect(screen.getByText(/Não enviada/)).toBeInTheDocument();
		expect(screen.getByText(/a sessão foi cancelada antes de ela sair/)).toBeInTheDocument();
	});

	it('só nomeia o participante quando há mais de um', () => {
		render(MessageTimeline, props());
		expect(screen.queryByText('Ana Souza')).not.toBeInTheDocument();

		cleanup();

		render(
			MessageTimeline,
			props({ participantes: [p(), p({ attendance_id: 'a2', patient_id: 'p2', paciente: 'João Lima' })] })
		);
		expect(screen.getByText('Ana Souza')).toBeInTheDocument();
		expect(screen.getByText('João Lima')).toBeInTheDocument();
	});

	// A timeline é histórico, e SÓ (doc 109). O "Reenviar" que morava aqui mudou de lugar: foi
	// para a linha do participante, no corpo do drawer, junto do resumo do estado de cada um.
	// Estes testes prendem as duas metades da decisão — nenhuma ação aqui, e o silêncio continua
	// sendo uma LINHA, que é a regra do §6 que este componente existe para cumprir.
	describe('histórico, não ação', () => {
		it('não oferece botão nenhum, nem depois de uma falha', () => {
			render(
				MessageTimeline,
				props({ participantes: [p({ mensagens: [msg({ status: 'falhou' })] })] })
			);

			expect(screen.queryByRole('button')).not.toBeInTheDocument();
		});

		it('o motivo do silêncio continua escrito, mesmo sem ação a oferecer', () => {
			// Tirar o botão não podia levar a explicação junto: sem ela, o participante fica com o
			// nome e o vazio abaixo — e vazio na tela lê-se como "já resolvido" (§6).
			for (const sem_envio of ['opt_out', 'canal_indisponivel', 'sem_contato'] as const) {
				render(MessageTimeline, props({ participantes: [p({ mensagens: [], sem_envio })] }));

				expect(screen.queryByRole('button')).not.toBeInTheDocument();
				cleanup();
			}
		});

		it('quem nunca recebeu nada ganha a linha do silêncio', () => {
			render(
				MessageTimeline,
				props({ participantes: [p({ mensagens: [], sem_envio: null })] })
			);

			expect(screen.getByText(SEM_COMUNICACAO)).toBeInTheDocument();
		});

		it('havendo motivo, é o motivo que aparece — não o texto genérico', () => {
			// A linha genérica não pode engolir a informação que diz o que fazer (abrir a ficha,
			// falar com o paciente). Ela é o caso "não há nada a explicar", só isso.
			render(
				MessageTimeline,
				props({ participantes: [p({ mensagens: [], sem_envio: 'sem_contato' })] })
			);

			expect(screen.getByText(/e-mail nem telefone/)).toBeInTheDocument();
			expect(screen.queryByText(SEM_COMUNICACAO)).not.toBeInTheDocument();
		});
	});
});
