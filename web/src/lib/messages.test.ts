import { describe, it, expect } from 'vitest';
import {
	algumPodeReceber,
	descarteTexto,
	instanteDoStatus,
	motivoDoBloqueio,
	podeReenviar,
	previsaoDeEnvio,
	respostaTexto,
	SEM_COMUNICACAO,
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
		agendadoPara: null,
		enviadoEm: '2026-08-10T12:00:05Z',
		entregueEm: null,
		lidoEm: null,
		falhouEm: null,
		descartadaEm: null,
		descarteMotivo: null,
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

	it('sem motivo E sem mensagem, o silêncio ainda tem texto', () => {
		// `semEnvioTexto(null)` devolver `null` não pode virar ausência de linha na tela: o §6 diz
		// que silêncio na tela faz a recepção supor que a mensagem saiu. Quem cobre esse caso é a
		// constante — e ela precisa dizer que NADA saiu, não por que não saiu (não há motivo).
		expect(SEM_COMUNICACAO).toMatch(/[a-z]/);
		expect(SEM_COMUNICACAO).not.toMatch(/Nada enviado ·/);
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

	it('adiada pelo silêncio NÃO é "enviada"', () => {
		// O 201 aqui significa "aceito", e a mensagem fica na fila até o fim da janela (§7).
		// Dizer "Mensagem enviada" manda a recepção esperar no telefone do paciente por algo que
		// só sai às 8h — a mesma classe de mentira do "Feito" que não enviava.
		const um = textoDoEnvio([
			{ patientId: 'p1', enviado: true, agendadoPara: '2026-08-11T11:00:00Z' }
		]);

		expect(um).toMatch(/na fila/i);
		expect(um).not.toMatch(/enviada/i);

		expect(
			textoDoEnvio([
				{ patientId: 'p1', enviado: true, agendadoPara: '2026-08-11T11:00:00Z' },
				{ patientId: 'p2', enviado: true, agendadoPara: '2026-08-11T11:00:00Z' }
			])
		).toMatch(/2 mensagens na fila/i);
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

describe('previsaoDeEnvio', () => {
	const agora = '2026-08-10T23:30:00Z';

	it('mensagem parada e adiada promete a hora de saída', () => {
		// A janela de silêncio (§7) adia; a tela mostrava só "Na fila" e o instante em que ela
		// ENTROU na fila, e quem lê conclui "não está enviando" — foi o relato ao vivo.
		const m = msg({ status: 'pendente', enviadoEm: null, agendadoPara: '2026-08-11T11:00:00Z' });

		expect(previsaoDeEnvio(m, agora)).toBe('2026-08-11T11:00:00Z');
	});

	it('sem adiamento não há promessa nenhuma', () => {
		expect(previsaoDeEnvio(msg({ status: 'pendente', agendadoPara: null }), agora)).toBeNull();
	});

	it('depois que saiu, a previsão não interessa mais', () => {
		// O que importa numa mensagem entregue é o que aconteceu, não o que se previa.
		const m = msg({ status: 'entregue', agendadoPara: '2026-08-11T11:00:00Z' });

		expect(previsaoDeEnvio(m, agora)).toBeNull();
	});

	it('hora já passada não vira promessa — ali o job está atrasado', () => {
		// "Sai às 8h" às 9h seria a tela mentindo com precisão.
		const m = msg({ status: 'pendente', enviadoEm: null, agendadoPara: '2026-08-10T11:00:00Z' });

		expect(previsaoDeEnvio(m, agora)).toBeNull();
	});

	it('descartada não promete saída — ela foi tirada da fila', () => {
		// O bug que originou o `:descartada`: o bloco é cancelado às 22h45 e a tela continuava
		// prometendo "sai qua., 08:00" para uma mensagem que não vai mais sair.
		const m = msg({
			status: 'descartada',
			enviadoEm: null,
			agendadoPara: '2026-08-11T11:00:00Z',
			descartadaEm: '2026-08-10T23:45:00Z',
			descarteMotivo: 'sessao_cancelada'
		});

		expect(previsaoDeEnvio(m, agora)).toBeNull();
	});
});

describe('descarteTexto', () => {
	it('explica por que a mensagem parou, para cada motivo', () => {
		expect(descarteTexto(msg({ status: 'descartada', descarteMotivo: 'sessao_cancelada' }))).toBe(
			'a sessão foi cancelada antes de ela sair'
		);

		expect(
			descarteTexto(msg({ status: 'descartada', descarteMotivo: 'agendamento_excluido' }))
		).toBe('o agendamento foi excluído antes de ela sair');
	});

	it('só fala de mensagem descartada', () => {
		expect(descarteTexto(msg({ status: 'enviado' }))).toBeNull();
	});

	it('motivo desconhecido não vira `undefined` na tela', () => {
		// Um átomo novo no backend chega aqui antes de o front saber dele; a linha continua
		// dizendo "Não enviada" sem despejar lixo no meio da frase.
		const m = msg({ status: 'descartada', descarteMotivo: 'motivo_novo' as never });

		expect(descarteTexto(m)).toBeNull();
	});

	it('o rótulo fala do que o paciente recebeu, não do verbo interno', () => {
		expect(statusTexto(msg({ status: 'descartada' }))).toBe('Não enviada');
	});

	it('o instante mostrado é o do descarte, não o da entrada na fila', () => {
		const m = msg({
			status: 'descartada',
			enviadoEm: null,
			enfileiradoEm: '2026-08-10T22:00:00Z',
			descartadaEm: '2026-08-10T23:45:00Z'
		});

		expect(instanteDoStatus(m)).toBe('2026-08-10T23:45:00Z');
	});
});

describe('podeReenviar', () => {
	it('NÃO oferece nada a quem nunca recebeu — quem envia a primeira é o rodapé', () => {
		// O "Enviar agora" por participante saiu da timeline: ela é histórico, não ação, e o
		// "Enviar confirmação" do rodapé já dispara para todo mundo. Dois botões para o mesmo
		// disparo davam à recepção duas respostas para a mesma pergunta.
		expect(podeReenviar(participante({ semEnvio: null }))).toBe(false);
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

	it('confirmação já na fila não conta — o servidor recusaria a duplicata', () => {
		// A trava do `Dispatch` (`:ja_na_fila`): o botão precisa dizer a mesma coisa que ela, senão
		// oferece um clique que só volta como aviso.
		const p = participante({ mensagens: [msg({ kind: 'confirmacao', status: 'pendente' })] });

		expect(algumPodeReceber([p])).toBe(false);
	});

	it('LEMBRETE na fila não impede a confirmação', () => {
		// A trava do servidor é por (presença, tipo). Travar aqui por qualquer pendente deixaria a
		// tela mais restritiva que a regra — divergência que ninguém percebe até alguém não
		// conseguir mandar.
		const p = participante({ mensagens: [msg({ kind: 'lembrete', status: 'pendente' })] });

		expect(algumPodeReceber([p])).toBe(true);
	});

	it('carregando não é impossível', () => {
		// `null` é a timeline em voo. Desabilitar por desconhecimento piscaria o botão a cada
		// abertura do drawer.
		expect(algumPodeReceber(null)).toBe(true);
	});

	it('sem participante nenhum, nada a enviar', () => {
		expect(algumPodeReceber([])).toBe(false);
	});

	// As duas travas novas (2026-07-29). São regra do `Dispatch` dos dois lados de propósito:
	// divergir aqui faria o botão prometer um clique que volta como aviso.
	it('quem JÁ CONFIRMOU não conta — não se pede o que já foi respondido', () => {
		const p = participante({
			mensagens: [msg({ kind: 'confirmacao', status: 'entregue', resposta: 'confirmou' })]
		});

		expect(algumPodeReceber([p])).toBe(false);
		expect(podeReenviar(p)).toBe(false);
	});

	it('confirmar pelo LEMBRETE também barra — o link viaja nos dois', () => {
		const p = participante({
			mensagens: [msg({ kind: 'lembrete', status: 'entregue', resposta: 'confirmou' })]
		});

		expect(algumPodeReceber([p])).toBe(false);
	});

	it('quem pediu para REMARCAR continua alcançável — a recepção resolve e reconfirma', () => {
		const p = participante({
			mensagens: [msg({ kind: 'confirmacao', status: 'entregue', resposta: 'quer_remarcar' })]
		});

		expect(algumPodeReceber([p])).toBe(true);
	});

	it('duas confirmações fecham o teto', () => {
		const p = participante({
			mensagens: [
				msg({ id: 'm1', kind: 'confirmacao', status: 'entregue' }),
				msg({ id: 'm2', kind: 'confirmacao', status: 'enviado' })
			]
		});

		expect(algumPodeReceber([p])).toBe(false);
		expect(podeReenviar(p)).toBe(false);
	});

	it('o que FALHOU ou foi DESCARTADO não gasta o teto', () => {
		// Nenhuma das duas falou com ninguém. Contá-las travaria justamente quem precisa reenviar:
		// a recepção que acabou de corrigir o e-mail na ficha.
		const p = participante({
			mensagens: [
				msg({ id: 'm1', kind: 'confirmacao', status: 'falhou' }),
				msg({ id: 'm2', kind: 'confirmacao', status: 'descartada' }),
				msg({ id: 'm3', kind: 'confirmacao', status: 'entregue' })
			]
		});

		expect(algumPodeReceber([p])).toBe(true);
	});

	it('o teto é da CONFIRMAÇÃO — lembrete e cancelamento não o gastam', () => {
		const p = participante({
			mensagens: [
				msg({ id: 'm1', kind: 'lembrete', status: 'entregue' }),
				msg({ id: 'm2', kind: 'cancelamento', status: 'entregue' }),
				msg({ id: 'm3', kind: 'confirmacao', status: 'entregue' })
			]
		});

		expect(algumPodeReceber([p])).toBe(true);
	});

	it('na turma, basta UM participante fora das travas', () => {
		// O botão do rodapé dispara para todos: barrado só quando ninguém pode receber.
		const confirmou = participante({
			mensagens: [msg({ kind: 'confirmacao', status: 'entregue', resposta: 'confirmou' })]
		});

		const livre = participante({ attendanceId: 'a2', patientId: 'p2', semEnvio: null });

		expect(algumPodeReceber([confirmou, livre])).toBe(true);
	});
});

describe('motivoDoBloqueio', () => {
	it('quem já confirmou e quem bateu o teto têm frases próprias', () => {
		const confirmou = participante({
			mensagens: [msg({ kind: 'confirmacao', status: 'entregue', resposta: 'confirmou' })]
		});

		const noTeto = participante({
			mensagens: [
				msg({ id: 'm1', kind: 'confirmacao', status: 'entregue' }),
				msg({ id: 'm2', kind: 'confirmacao', status: 'entregue' })
			]
		});

		expect(motivoDoBloqueio([confirmou])).toBe('o paciente já confirmou presença');
		expect(motivoDoBloqueio([noTeto])).toBe('já foram enviadas 2 confirmações para este paciente');
	});

	it('quem pode receber não tem bloqueio a explicar', () => {
		expect(motivoDoBloqueio([participante({ semEnvio: null })])).toBeNull();
		expect(motivoDoBloqueio(null)).toBeNull();
	});

	it('com motivos diferentes na turma, não escolhe um deles', () => {
		// Uma frase só mentiria para o outro participante. O `title` genérico manda ler a timeline,
		// que mostra os dois casos linha a linha.
		const confirmou = participante({
			mensagens: [msg({ kind: 'confirmacao', status: 'entregue', resposta: 'confirmou' })]
		});

		const semContato = participante({
			attendanceId: 'a2',
			patientId: 'p2',
			semEnvio: 'sem_contato'
		});

		expect(motivoDoBloqueio([confirmou, semContato])).toBeNull();
	});
});
