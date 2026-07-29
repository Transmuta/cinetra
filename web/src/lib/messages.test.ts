import { describe, it, expect } from 'vitest';
import {
	algumPodeReceber,
	instanteDoStatus,
	podeReenviar,
	respostaTexto,
	semEnvioTexto,
	statusTexto,
	textoDoEnvio,
	tituloDaLinha,
	type Message,
	type MessageParticipant
} from './messages';

// O vocabulário da timeline (doc 52 §6). O que precisa estar preso aqui é a regra do
// `podeReenviar`: ela é a que decide se a recepção vê um botão que de fato envia algo.

function msg(over: Partial<Message> = {}): Message {
	return {
		id: 'm1',
		canal: 'email',
		kind: 'confirmacao',
		status: 'enviado',
		destino: 'ana@example.com',
		erro: null,
		erroTexto: null,
		resposta: null,
		automatico: true,
		enfileiradoEm: '2026-08-10T12:00:00Z',
		enviadoEm: '2026-08-10T12:00:05Z',
		entregueEm: null,
		lidoEm: null,
		falhouEm: null,
		respondidoEm: null,
		titulo: 'Clínica: sua sessão',
		...over
	};
}

function participante(over: Partial<MessageParticipant> = {}): MessageParticipant {
	return {
		attendanceId: 'a1',
		patientId: 'p1',
		paciente: 'Ana',
		mensagens: [],
		semEnvio: null,
		...over
	};
}

describe('rótulos', () => {
	it('nomeia canal e motivo na mesma linha', () => {
		expect(tituloDaLinha(msg())).toBe('Confirmação por e-mail');
		expect(tituloDaLinha(msg({ kind: 'lembrete', canal: 'whatsapp' }))).toBe(
			'Lembrete por WhatsApp'
		);
	});

	it('traduz o estado', () => {
		expect(statusTexto(msg({ status: 'pendente' }))).toBe('Na fila');
		expect(statusTexto(msg({ status: 'falhou' }))).toBe('Falhou');
	});

	it('traduz a resposta do paciente', () => {
		expect(respostaTexto(msg())).toBeNull();
		expect(respostaTexto(msg({ resposta: 'confirmou' }))).toBe('Confirmou presença');
		expect(respostaTexto(msg({ resposta: 'quer_remarcar' }))).toBe('Pediu para remarcar');
	});
});

describe('semEnvioTexto', () => {
	it('cada motivo tem texto próprio — cada um leva a uma ação diferente', () => {
		// Colapsá-los num "não enviado" genérico tiraria da recepção justamente a informação que
		// diz o que fazer: abrir a ficha, preencher um campo, ou conversar com o paciente.
		expect(semEnvioTexto('sem_consentimento')).toMatch(/consentimento/);
		expect(semEnvioTexto('sem_contato')).toMatch(/e-mail nem telefone/);
		expect(semEnvioTexto('opt_out')).toMatch(/pediu para não receber/);
	});

	it('canal desligado NÃO diz que falta contato na ficha', () => {
		// O bug do balcão: paciente com celular cadastrado lia "sem e-mail nem telefone
		// cadastrado". A recepção abria a ficha, via o telefone lá, e não tinha o que corrigir.
		const texto = semEnvioTexto('canal_indisponivel') ?? '';

		expect(texto).toMatch(/WhatsApp/);
		expect(texto).not.toMatch(/cadastrado/);
	});

	it('motivo desconhecido não vira "undefined" na tela', () => {
		// O motivo vem da API: um átomo novo lá não pode virar texto quebrado aqui.
		expect(semEnvioTexto('motivo_do_futuro' as never)).toMatch(/[a-z]/);
	});

	it('sem motivo, não há linha', () => {
		expect(semEnvioTexto(null)).toBeNull();
	});
});

describe('textoDoEnvio', () => {
	it('nada enviado devolve o MOTIVO, não um "feito"', () => {
		// O pecado que esta função existe para não cometer: a API aceita o pedido (201) e o
		// Dispatch pula. Dizer "Feito" ali faz a recepção supor que a mensagem saiu — é o mesmo
		// silêncio que a timeline inteira foi desenhada para não produzir (§6).
		expect(textoDoEnvio([{ patientId: 'p1', enviado: false, motivo: 'canal_indisponivel' }])).toMatch(
			/WhatsApp/
		);
	});

	it('todos enviados diz que enviou', () => {
		expect(textoDoEnvio([{ patientId: 'p1', enviado: true }])).toBe('Mensagem enviada');
		expect(
			textoDoEnvio([
				{ patientId: 'p1', enviado: true },
				{ patientId: 'p2', enviado: true }
			])
		).toMatch(/2 pacientes/);
	});

	it('na turma, o parcial não vira sucesso limpo', () => {
		// "Enviada" com um participante fora seria mentira para aquele participante — a mesma
		// lição que a A2 já cobrou com a falta do bloco.
		const texto = textoDoEnvio([
			{ patientId: 'p1', enviado: true },
			{ patientId: 'p2', enviado: false, motivo: 'sem_contato' }
		]);

		expect(texto).toMatch(/1 de 2/);
		expect(texto).toMatch(/e-mail nem telefone/);
	});

	it('sem participante nenhum, não finge envio', () => {
		expect(textoDoEnvio([])).toMatch(/Nada/);
	});
});

describe('instanteDoStatus', () => {
	it('mostra o ponto mais avançado que a mensagem alcançou', () => {
		expect(instanteDoStatus(msg())).toBe('2026-08-10T12:00:05Z');
		expect(instanteDoStatus(msg({ entregueEm: '2026-08-10T12:01:00Z' }))).toBe(
			'2026-08-10T12:01:00Z'
		);
	});

	it('a falha vence tudo — é o que a recepção precisa ver', () => {
		expect(
			instanteDoStatus(
				msg({ status: 'falhou', entregueEm: '2026-08-10T12:01:00Z', falhouEm: '2026-08-10T12:02:00Z' })
			)
		).toBe('2026-08-10T12:02:00Z');
	});
});

describe('podeReenviar', () => {
	it('oferece envio a quem ainda não recebeu nada e nada bloqueia', () => {
		expect(podeReenviar(participante({ semEnvio: null }))).toBe(true);
	});

	it('NÃO oferece quando o envio é impossível agora', () => {
		// Todo motivo aqui é um `{:skip, _}` do Dispatch: o clique voltaria com a MESMA frase que a
		// linha acima já mostra. O opt-out é o §10.4 (não se contorna por insistência de botão); o
		// canal indisponível nem é da recepção.
		expect(podeReenviar(participante({ semEnvio: 'opt_out' }))).toBe(false);
		expect(podeReenviar(participante({ semEnvio: 'sem_contato' }))).toBe(false);
		expect(podeReenviar(participante({ semEnvio: 'sem_consentimento' }))).toBe(false);
		expect(podeReenviar(participante({ semEnvio: 'canal_indisponivel' }))).toBe(false);
	});

	it('oferece reenvio quando a última tentativa falhou', () => {
		expect(podeReenviar(participante({ mensagens: [msg({ status: 'falhou' })] }))).toBe(true);
	});

	it('não oferece quando já saiu ou está em trânsito', () => {
		// Oferecer aqui convida a recepção a duplicar comunicação com o paciente.
		expect(podeReenviar(participante({ mensagens: [msg({ status: 'enviado' })] }))).toBe(false);
		expect(podeReenviar(participante({ mensagens: [msg({ status: 'entregue' })] }))).toBe(false);
		expect(podeReenviar(participante({ mensagens: [msg({ status: 'pendente' })] }))).toBe(false);
	});

	it('olha a ÚLTIMA tentativa, não a primeira', () => {
		const p = participante({
			mensagens: [msg({ id: 'm1', status: 'falhou' }), msg({ id: 'm2', status: 'entregue' })]
		});

		expect(podeReenviar(p)).toBe(false);
	});
});

describe('algumPodeReceber', () => {
	it('basta um desimpedido na turma', () => {
		// O botão do rodapé dispara para todos: com um participante alcançável, ele tem o que fazer.
		expect(
			algumPodeReceber([
				participante({ semEnvio: 'canal_indisponivel' }),
				participante({ attendanceId: 'a2', patientId: 'p2', semEnvio: null })
			])
		).toBe(true);
	});

	it('com a turma inteira barrada, não há o que enviar', () => {
		expect(
			algumPodeReceber([
				participante({ semEnvio: 'canal_indisponivel' }),
				participante({ attendanceId: 'a2', patientId: 'p2', semEnvio: 'opt_out' })
			])
		).toBe(false);
	});

	it('quem já recebeu continua alcançável — reenviar de propósito é legítimo', () => {
		// Diferente do `podeReenviar`, que evita duplicar sozinho: aqui foi a recepção que pediu.
		expect(algumPodeReceber([participante({ mensagens: [msg({ status: 'entregue' })] })])).toBe(
			true
		);
	});

	it('carregando não é impossível', () => {
		// `null` é a timeline em voo. Desabilitar por desconhecimento piscaria o botão a cada
		// abertura do drawer.
		expect(algumPodeReceber(null)).toBe(true);
	});

	it('sem participante nenhum, nada a enviar', () => {
		expect(algumPodeReceber([])).toBe(false);
	});
});
