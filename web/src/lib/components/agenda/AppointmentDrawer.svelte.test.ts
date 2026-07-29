import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import type { Appointment, AgendaPatient, AgendaAppointmentType, AgendaProfessional } from '$lib/agenda';
import type { MessageParticipant } from '$lib/messages';

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
			{ patient_id: 'pac1', status: 'prevista', falta_justificada: false, motivo: null, package_id: null }
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
		expect(screen.getByText('08:00–08:50 (50min)')).toBeInTheDocument();
		expect(screen.getByText('João Silva')).toBeInTheDocument();
		expect(screen.getByText(/2 falta/)).toBeInTheDocument();
		// "Abrir ficha" aponta para a ficha do paciente.
		expect(screen.getByRole('link', { name: /Abrir ficha/ })).toHaveAttribute('href', '/pacientes/pac1');
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
							package_id: null
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
						{ patient_id: 'pac1', status: 'concluida', falta_justificada: false, motivo: null, package_id: null }
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
						{ patient_id: 'pac1', status: 'faltou', falta_justificada: false, motivo: null, package_id: null }
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
});
