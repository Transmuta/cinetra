import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import AppointmentBlock from './AppointmentBlock.svelte';
import type { Appointment, AttendanceStatus, Participant } from '$lib/agenda';

function appt(over: Partial<Appointment> = {}): Appointment {
	return {
		id: 'a1',
		starts_at: '2026-07-20T11:00:00Z',
		ends_at: '2026-07-20T11:50:00Z',
		status: 'agendado',
		encaixe: false,
		obs: null,
		professional_id: 'p1',
		appointment_type_id: 't1',
		version: 1,
		created_by_id: null,
		cancel_reason: null,
		reschedule_reason: null,
		veio_da_fila: false,
		dias_na_fila: null,
		patient_ids: ['pat1'],
		participants: [],
		...over
	};
}

const tipo = {
	id: 't1',
	nome: 'Sessão',
	sigla: 'SES',
	duracao_minutos: 50,
	cor: '#0072B2',
	icon: 'Activity',
	grupo: false,
	capacidade: null,
	ativo: true
};

const base = {
	appt: appt(),
	tipo,
	slot: { lane: 0, lanes: 1 },
	top: 0,
	height: 60,
	conflict: false,
	action: false,
	patientNames: ['Maria Silva'],
	profColor: '#0FB5A6',
	startLabel: '08:00',
	onSelect: () => {}
};

describe('AppointmentBlock', () => {
	// Doc 25 §6: `<button>`, não `<div>` clicável — um div com onclick não recebe foco,
	// não responde a Enter/Espaço e não é anunciado como acionável.
	it('é um <button> de verdade', () => {
		render(AppointmentBlock, { props: base });
		expect(screen.getByRole('button')).toBeInTheDocument();
	});

	it('aciona onSelect com o id ao clicar', async () => {
		const onSelect = vi.fn();
		render(AppointmentBlock, { props: { ...base, onSelect } });
		await userEvent.click(screen.getByRole('button'));
		expect(onSelect).toHaveBeenCalledWith('a1');
	});

	it('mostra a hora de início e o paciente', () => {
		render(AppointmentBlock, { props: base });
		expect(screen.getByText('08:00')).toBeInTheDocument();
		expect(screen.getByText('Maria Silva')).toBeInTheDocument();
	});

	// AN-01: a precedência do protótipo era `AÇÃO > conflito > status`, e existia porque as três
	// pintavam o mesmo retângulo. Agora não pintam: o status virou ponto+badge, e o fundo é
	// sempre branco. Sobra a BORDA, disputada por duas — e ela vai para o conflito, que é o fato
	// mais grave e o que tem menos voz (a pendência já tem o badge inteiro).
	describe('precedência da borda', () => {
		it('sem nada, é neutra', () => {
			render(AppointmentBlock, { props: base });
			expect(screen.getByRole('button')).toHaveAttribute('data-variant', 'status');
		});

		it('pendência tinge quando não há conflito', () => {
			render(AppointmentBlock, { props: { ...base, action: true } });
			expect(screen.getByRole('button')).toHaveAttribute('data-variant', 'action');
		});

		it('conflito ganha da pendência', () => {
			render(AppointmentBlock, { props: { ...base, conflict: true, action: true } });
			expect(screen.getByRole('button')).toHaveAttribute('data-variant', 'conflict');
		});
	});

	// HOM-004: o selo textual ENCAIXE virou ícone COM rótulo. A troca só é válida porque o
	// rótulo existe — um ícone mudo seria trocar um problema por outro.
	it('encaixe é ícone com rótulo, não sigla solta', () => {
		render(AppointmentBlock, { props: { ...base, appt: appt({ encaixe: true }) } });
		expect(screen.getByTitle(/encaixe/i)).toBeInTheDocument();
	});

	it('sem encaixe, não há marcador', () => {
		render(AppointmentBlock, { props: base });
		expect(screen.queryByTitle(/encaixe/i)).not.toBeInTheDocument();
	});

	// HOM-002/003: o status existia só como tinta e opacidade; o texto vivia no `aria-label`,
	// que é acessível e invisível ao mesmo tempo.
	describe('badge de status (AN-01 sub c)', () => {
		it('escreve o status no card', () => {
			render(AppointmentBlock, { props: base });
			expect(screen.getByTestId('status-badge')).toHaveTextContent('Agendado');
		});

		it('o fundo do bloco não é mais o status', () => {
			render(AppointmentBlock, {
				props: { ...base, appt: appt({ status: 'concluido' }) }
			});
			// Lido pela propriedade, não pelo texto do atributo: o browser normaliza o `style`
			// (insere espaço depois do `:`) e a asserção por string quebraria por formatação.
			expect((screen.getByRole('button') as HTMLElement).style.background).toBe(
				'var(--color-surface)'
			);
		});

		// HOM-003: `AÇÃO` era etiqueta genérica — não dizia o que fazer.
		it('a pendência vira verbo e substitui o status', () => {
			render(AppointmentBlock, { props: { ...base, action: true } });
			const badge = screen.getByTestId('status-badge');
			expect(badge).toHaveTextContent('Registrar status');
			expect(badge).not.toHaveTextContent('Agendado');
		});

		it('bloco de uma linha só não desenha badge (não cabe)', () => {
			render(AppointmentBlock, { props: { ...base, height: 20 } });
			expect(screen.queryByTestId('status-badge')).not.toBeInTheDocument();
		});
	});

	// D13 (doc 64 §3.2) — o achado do re-baseline. `Appointment.status` é um ROLLUP das
	// presenças e a regra é "alguma concluída ⇒ bloco concluído". Escrever "Concluído" numa
	// turma em que 1 veio e 3 faltaram seria afirmação falsa na tela.
	describe('turma mista não mente no badge', () => {
		const turma = { ...tipo, nome: 'Pilates', grupo: true, capacidade: 4 };
		const presenca = (status: AttendanceStatus, i: number): Participant => ({
			patient_id: `pat${i}`,
			status,
			falta_justificada: false, motivo: null,
			package_id: null,
			package: null
		});

		function turmaProps(statuses: AttendanceStatus[], height = 80) {
			return {
				...base,
				height,
				tipo: turma,
				appt: appt({
					status: 'concluido',
					patient_ids: statuses.map((_, i) => `pat${i}`),
					participants: statuses.map(presenca)
				}),
				patientNames: statuses.map((_, i) => `Paciente ${i}`)
			};
		}

		it('1 de 4 não vira "Concluído"', () => {
			render(AppointmentBlock, {
				props: turmaProps(['concluida', 'faltou', 'faltou', 'faltou'])
			});
			const badge = screen.getByTestId('status-badge');
			expect(badge).toHaveTextContent('1 de 4 concluídas');
			expect(badge).not.toHaveTextContent('Concluído');
		});

		it('turma inteira presente diz 4 de 4', () => {
			render(AppointmentBlock, {
				props: turmaProps(['concluida', 'concluida', 'concluida', 'concluida'])
			});
			expect(screen.getByTestId('status-badge')).toHaveTextContent('4 de 4 concluídas');
		});

		// Presença cancelada saiu da turma: não conta no numerador nem no denominador.
		it('presença cancelada sai da conta', () => {
			render(AppointmentBlock, {
				props: turmaProps(['concluida', 'concluida', 'cancelada'])
			});
			expect(screen.getByTestId('status-badge')).toHaveTextContent('2 de 2 concluídas');
		});

		// Sem ninguém registrado o rollup preserva a FASE, e é ela que vale — não há
		// composição a mostrar ainda.
		it('sem presença registrada, mostra a fase do bloco', () => {
			render(AppointmentBlock, {
				props: {
					...turmaProps(['prevista', 'prevista']),
					appt: appt({
						status: 'confirmado',
						patient_ids: ['pat0', 'pat1'],
						participants: [presenca('prevista', 0), presenca('prevista', 1)]
					})
				}
			});
			expect(screen.getByTestId('status-badge')).toHaveTextContent('Confirmado');
		});

		// Cancelar é do BLOCO, não das presenças — o rollup nem chega a opinar.
		it('bloco cancelado diz Cancelado, não composição', () => {
			render(AppointmentBlock, {
				props: {
					...turmaProps(['cancelada', 'cancelada']),
					appt: appt({
						status: 'cancelado',
						patient_ids: ['pat0', 'pat1'],
						participants: [presenca('cancelada', 0), presenca('cancelada', 1)]
					})
				}
			});
			expect(screen.getByTestId('status-badge')).toHaveTextContent('Cancelado');
		});
	});

	it('conflito é anunciado, não só colorido', () => {
		render(AppointmentBlock, { props: { ...base, conflict: true } });
		expect(screen.getByTitle(/conflito/i)).toBeInTheDocument();
	});

	it('cancelado sai riscado', () => {
		render(AppointmentBlock, { props: { ...base, appt: appt({ status: 'cancelado' }) } });
		expect(screen.getByRole('button')).toHaveAttribute('data-strike', 'true');
	});

	// Com o sidecar no ar, o bloco individual mostra o PACIENTE — não mais o nome do tipo,
	// que era o disfarce enquanto a fonte não existia.
	it('bloco individual mostra o nome do paciente, não o do tipo', () => {
		render(AppointmentBlock, { props: { ...base, height: 40 } });
		expect(screen.getByText('Maria Silva')).toBeInTheDocument();
		expect(screen.queryByText('Sessão')).not.toBeInTheDocument();
	});

	// O sidecar traz só os citados na janela, mas um id órfão (paciente removido entre a
	// leitura e o render) não pode deixar o bloco vazio nem derrubar a grade.
	it('paciente sem correspondência no sidecar cai num rótulo neutro', () => {
		render(AppointmentBlock, { props: { ...base, patientNames: [] } });
		expect(screen.getByText('Paciente')).toBeInTheDocument();
	});

	// HOM-005: era `Pilates · 3/4` no título, e "3/4" sozinho não diz de quê. O contador ganhou
	// linha própria e a palavra que faltava.
	it('turma conta vagas em texto, não em fração solta', () => {
		render(AppointmentBlock, {
			props: {
				...base,
				height: 80,
				appt: appt({ patient_ids: ['a', 'b', 'c'] }),
				tipo: { ...tipo, nome: 'Pilates', grupo: true, capacidade: 4 },
				patientNames: ['A', 'B', 'C']
			}
		});
		expect(screen.getByText('Pilates')).toBeInTheDocument();
		expect(screen.getByText('3/4 vagas ocupadas')).toBeInTheDocument();
		expect(screen.queryByText('Pilates · 3/4')).not.toBeInTheDocument();
	});

	// D1 (doc 64): os limiares são MEDIDOS no browser, não estimados — 78/61/44 é o que cada
	// variante de fato ocupa. E a conta é sobre a altura RENDERIZADA (`height - 2`), que é a que
	// existe na tela. A primeira versão errou os dois e o card encolhia o nome em silêncio.
	describe('escada de degradação por altura', () => {
		it.each([
			[80, '4'],
			[63, '3'],
			[46, '2'],
			[30, '1']
		])('altura %ipx desenha %s linha(s)', (height, linhas) => {
			render(AppointmentBlock, { props: { ...base, height } });
			expect(screen.getByRole('button')).toHaveAttribute('data-linhas', linhas);
		});

		// Os 2px do `height - 2` decidem a variante na fronteira: 46 renderiza 44, que é
		// exatamente o mínimo de duas linhas; 45 renderiza 43 e não cabe.
		it('a fronteira é a altura renderizada, não a recebida', () => {
			render(AppointmentBlock, { props: { ...base, height: 45 } });
			expect(screen.getByRole('button')).toHaveAttribute('data-linhas', '1');
		});

		// Na compacta o nome sobe para a linha da hora — empilhado ele seria espremido de 18px
		// para 9 e cortado no meio, sem nada quebrar.
		it('a variante compacta mantém o nome legível na linha da hora', () => {
			render(AppointmentBlock, { props: { ...base, height: 30 } });
			expect(screen.getByText('Maria Silva')).toBeInTheDocument();
			expect(screen.queryByTestId('status-badge')).not.toBeInTheDocument();
		});
	});

	// Rótulo por altura (protótipo :1687): bloco baixo não comporta a linha do nome em 12px.
	it('bloco muito baixo não desenha a terceira linha', () => {
		render(AppointmentBlock, { props: { ...base, height: 20 } });
		expect(screen.queryByText('Sessão')).not.toBeInTheDocument();
	});

	it('bloco alto mostra o nome do tipo na terceira linha', () => {
		render(AppointmentBlock, { props: { ...base, height: 80 } });
		expect(screen.getByText('Sessão')).toBeInTheDocument();
	});

	it('o nome acessível descreve o agendamento inteiro', () => {
		render(AppointmentBlock, { props: base });
		expect(screen.getByRole('button').getAttribute('aria-label')).toContain('08:00');
		expect(screen.getByRole('button').getAttribute('aria-label')).toContain('Maria Silva');
	});

	// O bloco de pacote era idêntico ao avulso: nem que é pacote, nem que sessão da série é.
	describe('selo de pacote', () => {
		const emPacote = (props = {}) => ({
			...base,
			height: 80,
			appt: appt({
				participants: [
					{
						patient_id: 'pat1',
						status: 'prevista' as AttendanceStatus,
						falta_justificada: false,
						motivo: null,
						package_id: 'k1',
						package: {
							nome: 'Pilates 10',
							sessao: 3,
							total: 10,
							falta_punitiva: true
						}
					}
				]
			}),
			...props
		});

		it('escreve a posição na série', () => {
			render(AppointmentBlock, { props: emPacote() });
			expect(screen.getByTestId('package-badge')).toHaveTextContent('3/10');
			expect(screen.getByTestId('package-badge')).toHaveAttribute(
				'title',
				'Pacote Pilates 10 · sessão 3 de 10'
			);
		});

		it('sessão avulsa não ganha selo', () => {
			render(AppointmentBlock, { props: { ...base, height: 80 } });
			expect(screen.queryByTestId('package-badge')).not.toBeInTheDocument();
		});

		// A terceira linha é onde o selo mora; abaixo dela o cartão não tem onde escrever, e o
		// pacote fica só no rótulo acessível — que não some nunca.
		it('bloco baixo mantém o pacote no rótulo acessível', () => {
			render(AppointmentBlock, { props: emPacote({ height: 30 }) });
			expect(screen.queryByTestId('package-badge')).not.toBeInTheDocument();
			expect(screen.getByRole('button').getAttribute('aria-label')).toContain(
				'Pacote Pilates 10 · sessão 3 de 10'
			);
		});
	});
});
