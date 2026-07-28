import { describe, it, expect } from 'vitest';
import {
	instanteDoStatus,
	podeReenviar,
	respostaTexto,
	semEnvioTexto,
	statusTexto,
	tituloDaLinha,
	type Message,
	type MessageParticipant
} from './messages';

// O vocabulário da timeline (doc 52 §6). O que precisa estar preso aqui é a regra do
// `podeReenviar`: ela é a que decide se a recepção consegue insistir com quem pediu para parar.

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

	it('sem motivo, não há linha', () => {
		expect(semEnvioTexto(null)).toBeNull();
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
	it('oferece envio a quem ainda não recebeu nada', () => {
		expect(podeReenviar(participante({ semEnvio: 'sem_contato' }))).toBe(true);
	});

	it('NÃO oferece a quem pediu para parar', () => {
		// A regra do §10.4 na UI: opt-out não se contorna por insistência de botão.
		expect(podeReenviar(participante({ semEnvio: 'opt_out' }))).toBe(false);
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
