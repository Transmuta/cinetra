import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import type { Appointment, AgendaPatient, AgendaAppointmentType, AgendaProfessional } from '$lib/agenda';
import type { Message, MessageParticipant } from '$lib/messages';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import AppointmentDrawer from './AppointmentDrawer.svelte';

const tipo: AgendaAppointmentType = {
	id: 't1',
	nome: 'Sessão',
	duracao_minutos: 50,
	cor: '#0072B2',
	icon: 'Activity',
	grupo: false,
	capacidade: null
};

const professional: AgendaProfessional = {
	id: 'p1',
	nome: 'Dra. Ana',
	nome_exibicao: null,
	crefito: null,
	cor_indice: 1,
	segue_horario_clinica: true
};

const patients: AgendaPatient[] = [{ id: 'pac1', nome: 'João Silva', tel: '11999', ativo: true, faltas: 2 }];

function appt(over: Partial<Appointment> = {}): Appointment {
	return {
		id: 'a1',
		starts_at: '2026-07-20T11:00:00Z',
		ends_at: '2026-07-20T11:50:00Z',
		status: 'agendado',
		encaixe: false,
		obs: null,
		cancel_reason: null,
		reschedule_reason: null,
		veio_da_fila: false,
		dias_na_fila: null,
		professional_id: 'p1',
		appointment_type_id: 't1',
		version: 3,
		created_by_id: null,
		patient_ids: ['pac1'],
		participants: [
			{
				patient_id: 'pac1',
				status: 'prevista',
				falta_justificada: false,
				motivo: null,
				package_id: null,
				package: null
			}
		],
		...over
	};
}

const base = {
	tipo,
	professional,
	patients,
	// 08:00 local < agora (14:00Z): a sessão já começou.
	agora: '2026-07-20T17:00:00Z',
	timezone: 'America/Sao_Paulo',
	papel: 'recepcao' as const,
	form: null,
	onClose: () => {},
	onReschedule: () => {},
	onToast: () => {}
};

describe('AppointmentDrawer', () => {
	it('mostra horário local, tipo e o cartão do paciente com faltas', () => {
		render(AppointmentDrawer, { props: { appt: appt(), ...base } });
		// O dia entrou na linha (doc 75, achado G) — e como o `agora` do fixture é o mesmo dia do
		// bloco, ele vira "hoje".
		expect(screen.getByTestId('drawer-horario')).toHaveTextContent('hoje · 08:00–08:50 (50min)');
		expect(screen.getByText('João Silva')).toBeInTheDocument();
		expect(screen.getByText(/2 falta/)).toBeInTheDocument();
		// "Abrir ficha" aponta para a ficha do paciente.
		expect(screen.getByRole('link', { name: /Abrir ficha/ })).toHaveAttribute('href', '/pacientes/pac1');
	});

	// O topo passou a responder QUEM antes de QUÊ: o paciente é o título, o profissional (com o
	// registro) é a legenda, e o status desceu para o corpo. Antes o cabeçalho era só o chip de
	// status — o nome de quem vai ser atendido aparecia a 150px dali, dentro do cartão.
	describe('cabeçalho', () => {
		it('o título é o paciente e a legenda é o profissional com o registro', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt(),
					...base,
					professional: { ...professional, nome: 'Dr. Rafael Couto', crefito: 'CREFITO 3/098234-F' }
				}
			});

			expect(screen.getByTestId('drawer-titulo')).toHaveTextContent('João Silva');
			expect(screen.getByTestId('drawer-legenda')).toHaveTextContent(
				'Dr. Rafael Couto · CREFITO 3/098234-F'
			);
		});

		// Sem registro cadastrado a legenda não inventa separador solto.
		it('profissional sem CREFITO não deixa o separador órfão', () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			expect(screen.getByTestId('drawer-legenda')).toHaveTextContent('Dra. Ana');
			expect(screen.getByTestId('drawer-legenda').textContent).not.toContain('·');
		});

		// Na turma não existe "o paciente" — o título é o tipo, como no cartão do grid. E aí a
		// linha "Tipo" do corpo repetiria o título, então ela sai.
		it('turma se intitula pelo tipo, e não repete o tipo abaixo', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt({ patient_ids: ['pac1'] }),
					...base,
					tipo: { ...tipo, nome: 'Pilates', grupo: true, capacidade: 4 }
				}
			});

			expect(screen.getByTestId('drawer-titulo')).toHaveTextContent('Pilates');
			expect(screen.queryByTestId('drawer-tipo')).not.toBeInTheDocument();
		});

		// O status saiu do cabeçalho, mas continua sendo a primeira coisa do corpo — e continua
		// saindo de `statusSignal` (achado A).
		it('o status desceu para o corpo, com o encaixe ao lado', () => {
			render(AppointmentDrawer, { props: { appt: appt({ encaixe: true }), ...base } });
			expect(screen.getByTestId('drawer-status')).toHaveTextContent('Agendado');
			expect(screen.getByText('ENCAIXE')).toBeInTheDocument();
		});

		// O nome do paciente aparecia DUAS vezes depois que o título passou a ser ele: no topo e
		// no cartão logo abaixo. Na sessão individual o cartão perde a linha do nome — o selo de
		// presença sobe para a linha do telefone.
		it('sessão individual não repete o nome do paciente', () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			expect(screen.getAllByText('João Silva')).toHaveLength(1);
		});

		// Na turma cada linha continua precisando do nome: ali ele identifica QUEM é aquela
		// presença, não o bloco.
		it('a turma continua nomeando cada participante', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt({ patient_ids: ['pac1'] }),
					...base,
					tipo: { ...tipo, grupo: true, capacidade: 4 }
				}
			});
			expect(screen.getByText('João Silva')).toBeInTheDocument();
		});
	});

	it('carrega os campos de versão em cada form (guard de 409)', () => {
		render(AppointmentDrawer, { props: { appt: appt(), ...base } });
		const v = document.querySelector<HTMLInputElement>('input[name="expected_version"]');
		expect(v?.value).toBe('3');
	});

	// A2 (doc 41): o desfecho deixou de ser um clique no BLOCO e virou presença por participante —
	// mesmo numa sessão individual, marca-se a presença daquele paciente.
	it('presente/faltou ficam DESABILITADOS antes de a sessão começar', () => {
		render(AppointmentDrawer, {
			props: { appt: appt(), ...base, agora: '2026-07-20T09:00:00Z' } // 09Z = 06:00 local
		});
		const presente = screen.getByRole('button', { name: 'Presente' });
		expect(presente).toBeDisabled();
		expect(presente).toHaveAttribute('title', 'Disponível após o horário da sessão');
	});

	it('presente/faltou ficam habilitados depois de começar', () => {
		render(AppointmentDrawer, { props: { appt: appt(), ...base } });
		expect(screen.getByRole('button', { name: 'Presente' })).toBeEnabled();
		expect(screen.getByRole('button', { name: 'Faltou' })).toBeEnabled();
	});

	// Regressão do bug que só o clique AO VIVO pegou: os campos são atribuídos e o form é
	// submetido logo em seguida. Sem esperar o flush do Svelte, o submit sai com os campos VAZIOS
	// (400 "Participante ou ação não informados") — e o `fireEvent` sozinho não denuncia, porque
	// ele já devolve depois do flush. Por isso a asserção é no MOMENTO do submit.
	it('o form da presença chega ao submit já preenchido', async () => {
		const capturado: Record<string, string> = {};
		const original = HTMLFormElement.prototype.requestSubmit;

		HTMLFormElement.prototype.requestSubmit = function () {
			for (const campo of ['patient_id', 'kind', 'justificada', 'motivo']) {
				capturado[campo] =
					this.querySelector<HTMLInputElement>(`input[name="${campo}"]`)?.value ?? '';
			}
		};

		try {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			// "Faltou" passou a abrir o diálogo do motivo (D-H3/D5) — o submit é o do diálogo.
			await fireEvent.click(screen.getByRole('button', { name: 'Faltou' }));
			await fireEvent.input(screen.getByPlaceholderText(/avisou que estava doente/i), {
				target: { value: 'avisou que estava doente' }
			});
			await fireEvent.click(screen.getByRole('button', { name: 'Registrar falta' }));
		} finally {
			HTMLFormElement.prototype.requestSubmit = original;
		}

		expect(capturado).toEqual({
			patient_id: 'pac1',
			kind: 'no_show',
			justificada: 'false',
			motivo: 'avisou que estava doente'
		});
	});

	// D-H3/D5: o motivo é opcional, e "opcional" tem de valer no caminho feliz — a recepção que
	// não quer explicar clica em registrar e pronto.
	it('registrar falta sem motivo submete mesmo assim', async () => {
		const capturado: Record<string, string> = {};
		const original = HTMLFormElement.prototype.requestSubmit;

		HTMLFormElement.prototype.requestSubmit = function () {
			capturado.kind = this.querySelector<HTMLInputElement>('input[name="kind"]')?.value ?? '';
			capturado.motivo = this.querySelector<HTMLInputElement>('input[name="motivo"]')?.value ?? '';
		};

		try {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			await fireEvent.click(screen.getByRole('button', { name: 'Faltou' }));
			await fireEvent.click(screen.getByRole('button', { name: 'Registrar falta' }));
		} finally {
			HTMLFormElement.prototype.requestSubmit = original;
		}

		expect(capturado).toEqual({ kind: 'no_show', motivo: '' });
	});

	// Concluir e reabrir NÃO abrem diálogo: não há motivo a registrar em nenhum dos dois, e uma
	// confirmação a mais em cada clique tornaria a marcação de turma insuportável.
	it('marcar presente continua em um clique', async () => {
		const original = HTMLFormElement.prototype.requestSubmit;
		let submeteu = false;
		HTMLFormElement.prototype.requestSubmit = function () {
			submeteu = true;
		};

		try {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			await fireEvent.click(screen.getByRole('button', { name: 'Presente' }));
		} finally {
			HTMLFormElement.prototype.requestSubmit = original;
		}

		expect(submeteu).toBe(true);
	});

	// Bate-volta: o motivo da falta era COLETADO e nunca relido. O irmão `cancel_reason` é
	// exibido depois do fato desde a Frente 4 — registrar sem poder consultar é meia entrega, e
	// justamente a metade que a gestão usa ("por que a clínica perde sessão?").
	it('o motivo da falta é exibido depois de registrado', () => {
		render(AppointmentDrawer, {
			props: {
				appt: appt({
					status: 'faltou',
					participants: [
						{
							patient_id: 'pac1',
							status: 'faltou',
							falta_justificada: false,
							motivo: 'não avisou',
							package_id: null,
							package: null
						}
					]
				}),
				...base
			}
		});
		expect(screen.getByText(/não avisou/)).toBeInTheDocument();
	});

	// Par do "Motivo do cancelamento", que já existia. Sem status na condição: um bloco remarcado
	// continua `agendado`, e amarrar a exibição a um status esconderia o motivo no único estado
	// em que ele é a informação nova.
	it('o motivo da remarcação é exibido num bloco agendado', () => {
		render(AppointmentDrawer, {
			props: { appt: appt({ reschedule_reason: 'profissional em congresso' }), ...base }
		});
		expect(screen.getByText(/profissional em congresso/)).toBeInTheDocument();
	});

	it('presença resolvida troca os botões por "Desfazer"', () => {
		render(AppointmentDrawer, {
			props: {
				appt: appt({
					status: 'concluido',
					participants: [
						{
							patient_id: 'pac1',
							status: 'concluida',
							falta_justificada: false,
							motivo: null,
							package_id: null,
							package: null
						}
					]
				}),
				...base
			}
		});
		expect(screen.getByRole('button', { name: 'Desfazer' })).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Presente' })).not.toBeInTheDocument();
	});

	it('bloco cancelado não oferece presença nenhuma (guard block_not_open)', () => {
		render(AppointmentDrawer, { props: { appt: appt({ status: 'cancelado' }), ...base } });
		expect(screen.queryByRole('button', { name: 'Presente' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Faltou' })).not.toBeInTheDocument();
	});

	it('estado terminal mostra "Reabrir"; agendado não', () => {
		const { unmount } = render(AppointmentDrawer, { props: { appt: appt({ status: 'faltou' }), ...base } });
		expect(screen.getByRole('button', { name: /Reabrir/ })).toBeInTheDocument();
		unmount();
		render(AppointmentDrawer, { props: { appt: appt(), ...base } });
		expect(screen.queryByRole('button', { name: /Reabrir/ })).not.toBeInTheDocument();
	});

	it('presença que faltou expõe o toggle de justificada — por participante', () => {
		render(AppointmentDrawer, {
			props: {
				appt: appt({
					status: 'faltou',
					participants: [
						{
							patient_id: 'pac1',
							status: 'faltou',
							falta_justificada: false,
							motivo: null,
							package_id: null,
							package: null
						}
					]
				}),
				...base
			}
		});
		expect(
			screen.getByRole('switch', { name: 'Justificar falta de João Silva' })
		).toBeInTheDocument();
	});

	it('cancelado mostra o motivo e esconde "Enviar confirmação"', () => {
		render(AppointmentDrawer, {
			props: { appt: appt({ status: 'cancelado', cancel_reason: 'paciente pediu' }), ...base }
		});
		expect(screen.getByText(/paciente pediu/)).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /Enviar confirmação/ })).not.toBeInTheDocument();
	});

	// O botão do rodapé promete disparo para o bloco inteiro. Com todo mundo barrado, o clique
	// voltava com o mesmo motivo que a seção Comunicação já explica — aviso no lugar de ação.
	describe('"Enviar confirmação" quando ninguém pode receber', () => {
		const mensagem = (over: Partial<Message> = {}): Message => ({
			id: 'm1',
			canal: 'email',
			kind: 'confirmacao',
			status: 'entregue',
			destino: 'joao@example.com',
			erro: null,
			erroTexto: null,
			resposta: null,
			automatico: true,
			enfileiradoEm: '2026-08-10T12:00:00Z',
			agendadoPara: null,
			enviadoEm: '2026-08-10T12:00:05Z',
			entregueEm: '2026-08-10T12:00:30Z',
			lidoEm: null,
			falhouEm: null,
			descartadaEm: null,
			descarteMotivo: null,
			respondidoEm: null,
			titulo: 'Clínica: sua sessão',
			...over
		});

		function timeline(semEnvio: MessageParticipant['semEnvio']): MessageParticipant[] {
			return [
				{ attendanceId: 'at1', patientId: 'pac1', paciente: 'João Silva', mensagens: [], semEnvio }
			];
		}

		it('desabilita, com o porquê no title', () => {
			render(AppointmentDrawer, {
				props: { appt: appt(), ...base, mensagens: timeline('canal_indisponivel') }
			});

			const botao = screen.getByRole('button', { name: /Enviar confirmação/ });
			expect(botao).toBeDisabled();
			// O motivo por extenso, e não mais "o motivo está em Comunicação": com um só motivo em
			// jogo, mandar a pessoa procurar a explicação em outro lugar é trabalho sem ganho.
			expect(botao).toHaveAttribute('title', 'o WhatsApp está indisponível e não há e-mail na ficha');
		});

		it('com motivos DIFERENTES na turma, o title volta a mandar ler a timeline', () => {
			// Uma frase única mentiria para um dos dois participantes. O genérico é o honesto — e a
			// seção Comunicação mostra os dois casos linha a linha.
			render(AppointmentDrawer, {
				props: {
					appt: appt(),
					...base,
					mensagens: [
						...timeline('sem_contato'),
						{
							attendanceId: 'at2',
							patientId: 'pac2',
							paciente: 'Ana Souza',
							mensagens: [mensagem({ status: 'entregue', resposta: 'confirmou' })],
							semEnvio: null
						}
					]
				}
			});

			const botao = screen.getByRole('button', { name: /Enviar confirmação/ });
			expect(botao).toBeDisabled();
			expect(botao).toHaveAttribute('title', expect.stringMatching(/Comunicação/));
		});

		it('segue habilitado com alguém alcançável', () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base, mensagens: timeline(null) } });

			expect(screen.getByRole('button', { name: /Enviar confirmação/ })).toBeEnabled();
		});

		it('a timeline em voo não desabilita nada', () => {
			// `mensagens` chega `null` até a busca do drawer voltar; desabilitar ali piscaria o botão.
			render(AppointmentDrawer, { props: { appt: appt(), ...base, mensagens: null } });

			expect(screen.getByRole('button', { name: /Enviar confirmação/ })).toBeEnabled();
		});

		// As duas travas de repetição (2026-07-29). Aqui o `title` diz QUAL é o motivo, e não o
		// genérico: mandar a recepção caçar na timeline para descobrir que não há nada a fazer é o
		// mesmo botão que promete e não cumpre, na forma passiva.
		function comMensagens(mensagens: Message[]): MessageParticipant[] {
			return [
				{ attendanceId: 'at1', patientId: 'pac1', paciente: 'João Silva', mensagens, semEnvio: null }
			];
		}

		it('quem já confirmou desabilita, e o title diz isso', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt(),
					...base,
					mensagens: comMensagens([mensagem({ status: 'entregue', resposta: 'confirmou' })])
				}
			});

			const botao = screen.getByRole('button', { name: /Enviar confirmação/ });
			expect(botao).toBeDisabled();
			expect(botao).toHaveAttribute('title', 'o paciente já confirmou presença');
		});

		it('o teto de duas confirmações desabilita, e o title diz isso', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt(),
					...base,
					mensagens: comMensagens([
						mensagem({ id: 'm1', status: 'entregue' }),
						mensagem({ id: 'm2', status: 'entregue' })
					])
				}
			});

			const botao = screen.getByRole('button', { name: /Enviar confirmação/ });
			expect(botao).toBeDisabled();
			expect(botao).toHaveAttribute('title', 'já foram enviadas 2 confirmações para este paciente');
		});

		it('uma confirmação só não fecha o teto', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt(),
					...base,
					mensagens: comMensagens([mensagem({ status: 'entregue' })])
				}
			});

			expect(screen.getByRole('button', { name: /Enviar confirmação/ })).toBeEnabled();
		});
	});

	// F3: o motivo do cancelamento existia na coluna e na tela de leitura, mas ninguém o
	// preenchia — cancelar era um clique só. O que estes testes travam é que cancelar PERGUNTA
	// (não submete direto) e que o motivo digitado viaja no form.
	describe('cancelar pergunta o motivo (F3)', () => {
		it('o botão Cancelar abre a confirmação em vez de submeter', async () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });

			const botao = screen.getByRole('button', { name: 'Cancelar sessão' });
			expect(botao).toHaveAttribute('type', 'button');

			await fireEvent.click(botao);

			// A confirmação abriu: o campo de motivo só existe dentro dela.
			expect(screen.getByPlaceholderText(/paciente pediu/i)).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Voltar' })).toBeInTheDocument();
		});

		it('o motivo digitado entra no form que a confirmação submete', async () => {
			const { container } = render(AppointmentDrawer, { props: { appt: appt(), ...base } });

			await fireEvent.click(screen.getByRole('button', { name: 'Cancelar sessão' }));
			await fireEvent.input(screen.getByPlaceholderText(/paciente pediu/i), {
				target: { value: 'imprevisto do profissional' }
			});

			const campo = container.querySelector('input[name="cancel_reason"]') as HTMLInputElement;
			expect(campo.value).toBe('imprevisto do profissional');
			expect(campo.form?.getAttribute('action')).toBe('?/cancelar');
		});

		it('Voltar fecha sem submeter', async () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });

			await fireEvent.click(screen.getByRole('button', { name: 'Cancelar sessão' }));
			await fireEvent.click(screen.getByRole('button', { name: 'Voltar' }));

			expect(screen.queryByPlaceholderText(/paciente pediu/i)).not.toBeInTheDocument();
		});
	});

	// Soft-delete (doc 40): o botão do rodapé (protótipo :1846) abre uma confirmação, distinta da
	// de cancelar — aqui o registro SOME. Só o que não aconteceu; concluído/faltou não oferecem.
	describe('excluir (soft-delete, doc 40)', () => {
		it('o botão do rodapé é ícone-só (aria-label) e abre a confirmação, não submete', async () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });

			const botao = screen.getByRole('button', { name: 'Excluir agendamento' });
			expect(botao).toHaveAttribute('type', 'button');
			// Fantasma até o hover: não é o vermelho sólido do "Enviar confirmação" ao lado.
			expect(botao.className).toContain('hover:text-danger');

			await fireEvent.click(botao);

			// A confirmação abriu e marca a diferença para o cancelar.
			expect(screen.getByText(/some/)).toBeInTheDocument();
			expect(screen.getByText(/use/)).toBeInTheDocument();
		});

		it('o form de exclusão aponta para ?/excluir com id + versão (guard 409)', () => {
			const { container } = render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			const form = container.querySelector('form[action="?/excluir"]') as HTMLFormElement;
			expect(form).toBeInTheDocument();
			expect(form.querySelector<HTMLInputElement>('input[name="expected_version"]')?.value).toBe('3');
			expect(form.querySelector<HTMLInputElement>('input[name="id"]')?.value).toBe('a1');
		});

		it('Voltar fecha a confirmação sem excluir', async () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			await fireEvent.click(screen.getByRole('button', { name: 'Excluir agendamento' }));
			await fireEvent.click(screen.getByRole('button', { name: 'Voltar' }));
			expect(screen.queryByText(/some/)).not.toBeInTheDocument();
		});

		it('um CANCELADO ainda pode ser excluído (é o caso comum "foi engano")', () => {
			render(AppointmentDrawer, { props: { appt: appt({ status: 'cancelado' }), ...base } });
			// Terminal: sem "Enviar confirmação", mas com o excluir (agora com rótulo).
			expect(screen.queryByRole('button', { name: /Enviar confirmação/ })).not.toBeInTheDocument();
			expect(screen.getByRole('button', { name: /Excluir/ })).toBeInTheDocument();
		});

		it('concluído/faltou NÃO oferecem excluir (aconteceu — reabrir antes)', () => {
			const { unmount } = render(AppointmentDrawer, { props: { appt: appt({ status: 'concluido' }), ...base } });
			expect(screen.queryByRole('button', { name: /Excluir/ })).not.toBeInTheDocument();
			unmount();
			render(AppointmentDrawer, { props: { appt: appt({ status: 'faltou' }), ...base } });
			expect(screen.queryByRole('button', { name: /Excluir/ })).not.toBeInTheDocument();
		});

		it('quem não pode mexer não vê o excluir', () => {
			render(AppointmentDrawer, { props: { appt: appt({ status: 'cancelado' }), ...base, papel: null } });
			expect(screen.queryByRole('button', { name: /Excluir/ })).not.toBeInTheDocument();
		});
	});

	it('turma mostra a lista de participantes com N/cap', () => {
		const grupo: AgendaAppointmentType = { ...tipo, grupo: true, capacidade: 4 };
		render(AppointmentDrawer, {
			props: {
				appt: appt({ patient_ids: ['pac1'] }),
				...base,
				tipo: grupo
			}
		});
		expect(screen.getByText('Pacientes na turma')).toBeInTheDocument();
		expect(screen.getByText('1/4')).toBeInTheDocument();
	});

	// Doc 74: sete arestas do drawer, cada uma com o seu porquê.
	describe('o que o drawer diz sobre o bloco (doc 75)', () => {
		const turma: AgendaAppointmentType = { ...tipo, grupo: true, capacidade: 4 };

		const presenca = (status: 'prevista' | 'concluida' | 'faltou', i: number) => ({
			patient_id: `pac${i}`,
			status,
			falta_justificada: false,
			motivo: null,
			package_id: null,
			package: null
		});

		// Achado A — o mais grave. O cartão usa `statusSignal` desde o D13 e escreve a composição;
		// o drawer usava `STATUS_META[status]` cru e escrevia a palavra da fase no mesmo bloco, a
		// 400px de distância. Duas verdades para o mesmo fato.
		//
		// O bloco aqui é NÃO-terminal de propósito: o rollup só resolve quando todas as presenças
		// vivas se resolvem (`Rollup.block_status`), então uma turma com um faltou e uma prevista
		// continua "confirmada" — e é aí que a composição aparece sem o desfecho de ninguém.
		it('o chip não mente numa turma parcialmente registrada', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt({
						status: 'confirmado',
						patient_ids: ['pac1', 'pac2'],
						participants: [presenca('faltou', 1), presenca('prevista', 2)]
					}),
					...base,
					tipo: turma,
					patients: [...patients, { id: 'pac2', nome: 'Ana Paula', tel: null, ativo: true }]
				}
			});

			expect(screen.getByTestId('drawer-status')).toHaveTextContent('0 de 2 concluídas');
			expect(screen.queryByText('Confirmado')).not.toBeInTheDocument();
		});

		// O bloco RESOLVIDO dizia o desfecho duas vezes: no chip do topo ("Cancelado") e no selo da
		// presença logo abaixo ("Cancelada"). Quem manda é a PRESENÇA — o status do bloco é rollup
		// dela (A2/D13) —, então o chip se cala quando há desfecho a ler ali.
		it('bloco resolvido não repete o desfecho no topo', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt({
						status: 'cancelado',
						participants: [
							{
								patient_id: 'pac1',
								status: 'cancelada',
								falta_justificada: false,
								motivo: null,
								package_id: null,
								package: null
							}
						]
					}),
					...base
				}
			});

			expect(screen.queryByTestId('drawer-status')).not.toBeInTheDocument();
			expect(screen.getByText('Cancelada')).toBeInTheDocument();
		});

		// ...mas enquanto NÃO há desfecho, o participante fica calado (o selo só existe a partir de
		// "Previsto"), e a fase do bloco é a única coisa que responde "e aí, como está isso?".
		it('bloco em andamento mantém a fase no topo', () => {
			render(AppointmentDrawer, { props: { appt: appt({ status: 'confirmado' }), ...base } });
			expect(screen.getByTestId('drawer-status')).toHaveTextContent('Confirmado');
		});

		// O encaixe não é status: ele qualifica o bloco resolvido igual ao que ainda vai acontecer.
		it('o encaixe sobrevive ao chip que sumiu', () => {
			render(AppointmentDrawer, {
				props: { appt: appt({ status: 'cancelado', encaixe: true }), ...base }
			});
			expect(screen.queryByTestId('drawer-status')).not.toBeInTheDocument();
			expect(screen.getByText('ENCAIXE')).toBeInTheDocument();
		});

		// Achado B — "0 falta(s)" é ruído: ninguém age sobre a ausência de falta. E a turma já o
		// escondia, então eram duas regras para o mesmo fato na mesma tela.
		it('falta zero não aparece, e o plural é de gente', () => {
			render(AppointmentDrawer, {
				props: { appt: appt(), ...base, patients: [{ ...patients[0], faltas: 0 }] }
			});
			expect(screen.queryByText(/falta/)).not.toBeInTheDocument();
			expect(screen.getByText('João Silva')).toBeInTheDocument();
		});

		it('uma falta só não vira "1 faltas"', () => {
			render(AppointmentDrawer, {
				props: { appt: appt(), ...base, patients: [{ ...patients[0], faltas: 1 }] }
			});
			expect(screen.getByText(/1 falta$/)).toBeInTheDocument();
		});

		// Achado C — `veio_da_fila`/`dias_na_fila` são carimbados na conversão (D-H10) e nenhuma
		// tela os lia. É o que fecha o ciclo: esta vaga foi coberta pela fila, depois de N dias.
		it('bloco que veio da fila diz isso, com a espera', () => {
			render(AppointmentDrawer, {
				props: { appt: appt({ veio_da_fila: true, dias_na_fila: 6 }), ...base }
			});
			expect(screen.getByTestId('drawer-origem')).toHaveTextContent(
				'Fila de espera · esperou 6 dias'
			);
		});

		it('bloco comum não fala em fila', () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			expect(screen.queryByTestId('drawer-origem')).not.toBeInTheDocument();
		});

		// Achado D — a observação era uma caixa cinza anônima ao lado de duas idênticas que têm
		// rótulo ("Motivo do cancelamento", "da remarcação").
		it('a observação tem rótulo, como os motivos', () => {
			render(AppointmentDrawer, { props: { appt: appt({ obs: 'levar exame' }), ...base } });
			expect(screen.getByText('Observação:')).toBeInTheDocument();
		});

		// Achado G — no celular o painel é `max-w-full` e cobre o cabeçalho da agenda, que era
		// onde o dia estava. O drawer mostrava só "08:00–08:50".
		it('o horário carrega o dia', () => {
			// `agora` num dia diferente do bloco: é o caso que o "hoje" esconde.
			render(AppointmentDrawer, { props: { appt: appt(), ...base, agora: '2026-07-25T17:00:00Z' } });
			expect(screen.getByTestId('drawer-horario')).toHaveTextContent(
				'seg, 20/07 · 08:00–08:50 (50min)'
			);
		});

		it('no dia corrente, o dia vira "hoje"', () => {
			render(AppointmentDrawer, {
				props: { appt: appt(), ...base, agora: '2026-07-20T17:00:00Z' }
			});
			expect(screen.getByTestId('drawer-horario')).toHaveTextContent('hoje · 08:00–08:50');
		});

		// Achado E — o drawer é a tela de onde a recepção liga.
		it('o telefone disca', () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			expect(document.querySelector('a[href^="tel:"]')).toHaveAttribute('href', 'tel:11999');
		});

		// Achado F — o botão desabilitado repetia o chip do header e ocupava a linha do "Reabrir".
		it('bloco cancelado não mostra um "Cancelado" desabilitado', () => {
			render(AppointmentDrawer, { props: { appt: appt({ status: 'cancelado' }), ...base } });
			expect(screen.queryByRole('button', { name: /Cancelar sessão|^Cancelado$/ })).not.toBeInTheDocument();
			expect(screen.getByRole('button', { name: /Reabrir/ })).toBeInTheDocument();
		});

		it('bloco aberto continua oferecendo cancelar', () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			expect(screen.getByRole('button', { name: /Cancelar sessão/ })).toBeInTheDocument();
		});
	});

	// O cartão da agenda passou a dizer "3/10"; o drawer é onde esse número vira frase. E ele mora
	// DENTRO do participante, não numa seção do bloco: o pacote é por presença (D11) e numa turma
	// cada um consome do seu.
	describe('sessão de pacote', () => {
		const pacote = (over: Record<string, unknown> = {}) => ({
			nome: 'Pilates 10',
			sessao: 3,
			total: 10,
			falta_punitiva: true,
			...over
		});

		const comPacote = (over: Record<string, unknown> = {}, appointment: Record<string, unknown> = {}) =>
			appt({
				participants: [
					{
						patient_id: 'pac1',
						status: 'prevista' as const,
						falta_justificada: false,
						motivo: null,
						package_id: 'k1',
						package: pacote(over),
						...(appointment.participante as object)
					}
				],
				...appointment
			});

		it('escreve o pacote e a posição na série', () => {
			render(AppointmentDrawer, { props: { appt: comPacote(), ...base } });
			expect(screen.getByText('Pilates 10')).toBeInTheDocument();
			expect(screen.getByText(/3 de 10/)).toBeInTheDocument();
		});

		// O saldo saiu: a caixa dizia três coisas onde cabiam duas, e "quantas sobram" é pergunta
		// da ficha, não do bloco. O campo saiu junto do contrato — ver o teste do controller.
		it('não fala em saldo', () => {
			render(AppointmentDrawer, { props: { appt: comPacote(), ...base } });
			expect(screen.queryByText(/restantes/)).not.toBeInTheDocument();
		});

		it('sessão avulsa não ganha nada disso', () => {
			render(AppointmentDrawer, { props: { appt: appt(), ...base } });
			expect(screen.queryByTestId('drawer-pacote')).not.toBeInTheDocument();
		});

		// A frase que a recepção precisa ANTES da falta, não depois.
		it('antes do desfecho, avisa que faltar consome', () => {
			render(AppointmentDrawer, { props: { appt: comPacote(), ...base } });
			expect(screen.getByText('Falta debita 1 sessão deste pacote')).toBeInTheDocument();
		});

		it('depois da falta, diz que debitou', () => {
			const faltou = appt({
				status: 'faltou',
				participants: [
					{
						patient_id: 'pac1',
						status: 'faltou',
						falta_justificada: false,
						motivo: null,
						package_id: 'k1',
						package: pacote()
					}
				]
			});
			render(AppointmentDrawer, { props: { appt: faltou, ...base } });
			expect(screen.getByText('Esta falta debitou 1 sessão')).toBeInTheDocument();
		});

		// A linha inteira é o link, e ele leva à SEÇÃO de pacotes da ficha — a âncora existe em
		// `PackageList` para não cair no topo e deixar quem clicou procurando.
		it('o pacote leva à seção de pacotes da ficha', () => {
			render(AppointmentDrawer, { props: { appt: comPacote(), ...base } });
			expect(screen.getByTestId('drawer-pacote').querySelector('a')).toHaveAttribute(
				'href',
				'/pacientes/pac1#pacotes'
			);
		});

		it('numa turma, cada participante mostra o SEU pacote', () => {
			const grupo: AgendaAppointmentType = { ...tipo, grupo: true, capacidade: 4 };
			const turma = appt({
				patient_ids: ['pac1', 'pac2'],
				participants: [
					{
						patient_id: 'pac1',
						status: 'prevista',
						falta_justificada: false,
						motivo: null,
						package_id: 'k1',
						package: pacote()
					},
					{
						patient_id: 'pac2',
						status: 'prevista',
						falta_justificada: false,
						motivo: null,
						package_id: 'k2',
						package: pacote({ nome: 'RPG 8', sessao: 1, total: 8 })
					}
				]
			});

			render(AppointmentDrawer, {
				props: {
					appt: turma,
					...base,
					tipo: grupo,
					patients: [...patients, { id: 'pac2', nome: 'Ana Paula', tel: null, ativo: true }]
				}
			});

			expect(screen.getAllByTestId('drawer-pacote')).toHaveLength(2);
			expect(screen.getByText('Pilates 10')).toBeInTheDocument();
			expect(screen.getByText('RPG 8')).toBeInTheDocument();
		});
	});

	// AN-12 (doc 64, D11): a vaga que abriu (cancelamento/falta) pergunta à fila "quem cabe
	// aqui?" — a seção só existe nesses dois status, e agendar um candidato converte a entry NA
	// vaga do próprio bloco.
	describe('quem cabe aqui (AN-12)', () => {
		const candidato = (over: Record<string, unknown> = {}) => ({
			id: 'e1',
			prio: 'urgente' as const,
			janela: 'qualquer' as const,
			obs: null,
			professional_ids: [],
			dias_na_fila: 5,
			rules: [],
			patient: { id: 'pacf', nome: 'Bia Fila', tel: null, ativo: true, faltas: 0 },
			inserted_at: '2026-07-15T12:00:00Z',
			...over
		});

		it('bloco cancelado lista o candidato com prioridade e tempo de fila', () => {
			render(AppointmentDrawer, {
				props: { appt: appt({ status: 'cancelado' }), ...base, candidatos: [candidato()] }
			});
			expect(screen.getByText('Quem cabe aqui')).toBeInTheDocument();
			expect(screen.getByText('Bia Fila')).toBeInTheDocument();
			expect(screen.getByText('Urgente')).toBeInTheDocument();
			expect(screen.getByText(/5 dia\(s\) na fila/)).toBeInTheDocument();
			expect(screen.getByRole('link', { name: /Ver fila/ })).toHaveAttribute('href', '/fila');
		});

		it('bloco agendado NÃO tem a seção (não há vaga nenhuma)', () => {
			render(AppointmentDrawer, {
				props: { appt: appt(), ...base, candidatos: [candidato()] }
			});
			expect(screen.queryByText('Quem cabe aqui')).not.toBeInTheDocument();
		});

		it('null = consultando; lista vazia diz que ninguém casa', () => {
			const { unmount } = render(AppointmentDrawer, {
				props: { appt: appt({ status: 'cancelado' }), ...base, candidatos: null }
			});
			expect(screen.getByText(/Consultando a fila/)).toBeInTheDocument();
			unmount();
			render(AppointmentDrawer, {
				props: { appt: appt({ status: 'cancelado' }), ...base, candidatos: [] }
			});
			expect(screen.getByText(/Ninguém na fila casa com este horário/)).toBeInTheDocument();
		});

		it('Agendar submete a conversão com o slot do bloco (sem encaixe no cancelado)', async () => {
			const capturado: Record<string, string> = {};
			const original = HTMLFormElement.prototype.requestSubmit;

			HTMLFormElement.prototype.requestSubmit = function () {
				if (this.getAttribute('action') !== '?/agendar_fila') return;
				for (const campo of ['id', 'starts_at', 'professional_id', 'appointment_type_id', 'duration_minutos', 'encaixe']) {
					capturado[campo] = this.querySelector<HTMLInputElement>(`input[name="${campo}"]`)?.value ?? '';
				}
			};

			try {
				render(AppointmentDrawer, {
					props: { appt: appt({ status: 'cancelado' }), ...base, candidatos: [candidato()] }
				});
				await fireEvent.click(screen.getByRole('button', { name: 'Agendar' }));
			} finally {
				HTMLFormElement.prototype.requestSubmit = original;
			}

			expect(capturado).toEqual({
				id: 'e1',
				starts_at: '2026-07-20T11:00:00Z',
				professional_id: 'p1',
				appointment_type_id: 't1',
				duration_minutos: '50',
				encaixe: 'false'
			});
		});

		// A falta ocupa o horário para a exclusion constraint (`status <> 'cancelado'`): cobrir a
		// vaga de uma falta SÓ entra como encaixe, e o form já parte assim.
		it('na vaga de falta o encaixe viaja true', async () => {
			let encaixe = '';
			const original = HTMLFormElement.prototype.requestSubmit;
			HTMLFormElement.prototype.requestSubmit = function () {
				if (this.getAttribute('action') !== '?/agendar_fila') return;
				encaixe = this.querySelector<HTMLInputElement>('input[name="encaixe"]')?.value ?? '';
			};

			try {
				render(AppointmentDrawer, {
					props: { appt: appt({ status: 'faltou' }), ...base, candidatos: [candidato()] }
				});
				await fireEvent.click(screen.getByRole('button', { name: 'Agendar' }));
			} finally {
				HTMLFormElement.prototype.requestSubmit = original;
			}

			expect(encaixe).toBe('true');
		});

		// A9/D2: profissional não marca encaixe — e na vaga de falta a conversão é encaixe por
		// definição, então o botão nem oferece o caminho que o servidor recusaria.
		it('profissional não agenda na vaga de falta (encaixe é de quem responde pela agenda)', () => {
			render(AppointmentDrawer, {
				props: {
					appt: appt({ status: 'faltou' }),
					...base,
					papel: 'profissional' as const,
					candidatos: [candidato()]
				}
			});
			expect(screen.getByRole('button', { name: 'Agendar' })).toBeDisabled();
		});

		// O horário foi tomado no meio-tempo (vaga de cancelamento re-ocupada): o 422 volta com a
		// saída de encaixe — mesmo desenho do criar/remarcar (ConflictErrorBox).
		it('schedule_conflict oferece "Marcar como encaixe", que arma o flag', async () => {
			const capturas: string[] = [];
			const original = HTMLFormElement.prototype.requestSubmit;
			HTMLFormElement.prototype.requestSubmit = function () {
				if (this.getAttribute('action') !== '?/agendar_fila') return;
				capturas.push(this.querySelector<HTMLInputElement>('input[name="encaixe"]')?.value ?? '');
			};

			try {
				render(AppointmentDrawer, {
					props: {
						appt: appt({ status: 'cancelado' }),
						...base,
						candidatos: [candidato()],
						form: {
							action: 'agendar_fila',
							error: 'Esse horário sobrepõe outro agendamento.',
							code: 'schedule_conflict'
						}
					}
				});

				expect(screen.getByText(/sobrepõe/)).toBeInTheDocument();
				await fireEvent.click(screen.getByRole('button', { name: 'Marcar como encaixe' }));
				await fireEvent.click(screen.getByRole('button', { name: 'Agendar' }));
			} finally {
				HTMLFormElement.prototype.requestSubmit = original;
			}

			expect(capturas).toEqual(['true']);
		});
	});
});
