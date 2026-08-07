import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import type { Message, MessageParticipant } from '$lib/messages';

import ParticipantCommunication from './ParticipantCommunication.svelte';

// A comunicação de UMA pessoa, na linha dela (doc 109). O que precisa estar preso aqui é o que a
// integração no drawer não alcança: o estado de CARREGANDO e a PREVISÃO de envio — os dois casos
// em que a tela é mais fácil de deixar mentindo por omissão.

function msg(over: Partial<Message> = {}): Message {
	return {
		id: 'm1',
		canal: 'email',
		kind: 'confirmacao',
		status: 'entregue',
		destino: 'ana@example.com',
		erro: null,
		erro_texto: null,
		resposta: null,
		automatico: false,
		enfileirado_em: '2026-08-10T01:00:00Z',
		agendado_para: null,
		enviado_em: '2026-08-10T01:00:05Z',
		entregue_em: '2026-08-10T01:00:09Z',
		lido_em: null,
		falhou_em: null,
		descartada_em: null,
		descarte_motivo: null,
		respondido_em: null,
		titulo: 'Sua sessão',
		...over
	};
}

function participante(over: Partial<MessageParticipant> = {}): MessageParticipant {
	return {
		attendance_id: 'att1',
		patient_id: 'pac1',
		paciente: 'Ana Souza',
		mensagens: [],
		sem_envio: null,
		...over
	};
}

const base = {
	timezone: 'America/Sao_Paulo',
	agora: '2026-08-10T12:00:00Z',
	podeEnviar: true
};

describe('ParticipantCommunication', () => {
	// Carregando ≠ "nada a dizer". Um vazio aqui leria como "já resolvido", que é exatamente o
	// silêncio inexplicado que o §6 existe para impedir.
	it('enquanto a timeline carrega, diz que está carregando', () => {
		render(ParticipantCommunication, { props: { ...base, carregando: true } });

		expect(screen.getByText('Comunicação…')).toBeInTheDocument();
	});

	// Participante recém-adicionado à turma: a timeline ainda não fala dele, e ela já terminou de
	// carregar. Não há o que afirmar — e afirmar "nada enviado" seria inventar um fato.
	it('sem linha na timeline e sem carregamento, não desenha nada', () => {
		const { container } = render(ParticipantCommunication, { props: { ...base } });

		expect(container.textContent?.trim()).toBe('');
	});

	it('resume o estado e oferece o disparo com o nome da pessoa', async () => {
		const onEnviar = vi.fn();
		render(ParticipantCommunication, {
			props: { ...base, participante: participante(), onEnviar }
		});

		expect(screen.getByText(/Nenhuma comunicação enviada/)).toBeInTheDocument();

		await fireEvent.click(
			screen.getByRole('button', { name: 'Enviar confirmação para Ana Souza' })
		);

		expect(onEnviar).toHaveBeenCalledWith('pac1');
	});

	// A janela de silêncio (§7) ADIA. O instante útil aqui é o futuro: "entrou na fila às 22h" não
	// responde a pergunta de quem está lendo.
	it('mensagem adiada promete a saída, não o instante em que entrou na fila', () => {
		render(ParticipantCommunication, {
			props: {
				...base,
				participante: participante({
					mensagens: [
						msg({
							status: 'pendente',
							enviado_em: null,
							entregue_em: null,
							agendado_para: '2026-08-11T11:00:00Z'
						})
					]
				})
			}
		});

		// 11:00Z = 08:00 em São Paulo, na terça.
		expect(screen.getByText(/sai ter/)).toBeInTheDocument();
		expect(screen.queryByText(/dom/)).not.toBeInTheDocument();
	});

	// Sem botão, mas COM o porquê: um vazio no lugar da ação faz a recepção procurar o que não
	// existe. O motivo é o mesmo `{:skip, _}` que o servidor devolveria.
	it('quem está barrado não ganha botão, e o motivo fica no title', () => {
		render(ParticipantCommunication, {
			props: { ...base, participante: participante({ sem_envio: 'opt_out' }) }
		});

		expect(screen.queryByRole('button')).not.toBeInTheDocument();
		expect(screen.getByTitle('o paciente pediu para não receber')).toBeInTheDocument();
	});

	it('sem permissão de escrita, é só leitura', () => {
		render(ParticipantCommunication, {
			props: { ...base, podeEnviar: false, participante: participante() }
		});

		expect(screen.getByText(/Nenhuma comunicação enviada/)).toBeInTheDocument();
		expect(screen.queryByRole('button')).not.toBeInTheDocument();
	});

	// Outro disparo em voo desabilita este, mas sem fingir que é ESTE que está carregando — o giro
	// no botão errado faz a recepção achar que clicou onde não clicou.
	it('disparo do colega desabilita sem roubar o sinal de carregando', () => {
		render(ParticipantCommunication, {
			props: { ...base, participante: participante(), bloqueado: true, emVoo: false }
		});

		const botao = screen.getByRole('button', { name: /Enviar confirmação para Ana Souza/ });
		expect(botao).toBeDisabled();
		expect(botao).toHaveAttribute('aria-busy', 'false');
	});
});
