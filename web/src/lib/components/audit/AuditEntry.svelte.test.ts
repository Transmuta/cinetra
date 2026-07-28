import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';
import AuditEntry from './AuditEntry.svelte';
import type { AuditEntry as Entry } from '$lib/audit';
import { auditEntryFixture } from '$lib/testing/fixtures';

const TZ = 'America/Sao_Paulo';

// A forma vem da fábrica compartilhada; aqui só os defaults que este arquivo assume — um
// CANCELAMENTO, que é a entrada com diff. (Antes esta função reescrevia os 13 campos.)
function entry(over: Partial<Entry> = {}): Entry {
	return auditEntryFixture({
		action: 'cancel',
		action_type: 'update',
		// `status` deixou de ser campo da entrada (doc 63): o contexto por recurso viaja em `meta`,
		// porque a maioria dos catorze recursos não tem "situação" nenhuma.
		diff: [{ field: 'status', from: 'agendado', to: 'cancelado' }],
		...over
	});
}

afterEach(cleanup);

describe('AuditEntry', () => {
	it('a manchete é o FATO; o autor desce para a terceira linha', () => {
		const { getByRole, getByText } = render(AuditEntry, { props: { entry: entry(), timezone: TZ } });
		expect(getByRole('heading', { name: 'Cancelou o agendamento' })).toBeInTheDocument();
		expect(getByText('por Ana Gestora')).toBeInTheDocument();
	});

	it('a segunda linha diz de qual sessão se fala', () => {
		const { getByText } = render(AuditEntry, { props: { entry: entry(), timezone: TZ } });
		expect(getByText('Dra. Bea · seg 20/07, 08:00')).toBeInTheDocument();
	});

	// Dentro de um grupo que já é o dia, repetir "20/07/2026" em 50 linhas é ruído — a data
	// completa fica no `title` (e no `datetime`, para quem lê a máquina).
	it('mostra só a hora, com o carimbo completo no title', () => {
		const { getByText } = render(AuditEntry, { props: { entry: entry(), timezone: TZ } });
		const time = getByText('11:30');
		expect(time).toHaveAttribute('title', '20/07/2026 11:30');
		expect(time).toHaveAttribute('datetime', '2026-07-20T14:30:00Z');
	});

	it('numa atualização mostra o diff campo-a-campo', () => {
		const { getByText } = render(AuditEntry, { props: { entry: entry(), timezone: TZ } });
		expect(getByText('Situação:')).toBeInTheDocument();
		expect(getByText('Cancelado')).toBeInTheDocument();
	});

	it('numa CRIAÇÃO não mostra o diff (o verbo já explica)', () => {
		const { queryByText } = render(AuditEntry, {
			props: {
				entry: entry({ action: 'schedule', action_type: 'create', diff: [{ field: 'status', from: null, to: 'agendado' }] }),
				timezone: TZ
			}
		});
		expect(queryByText('Situação:')).toBeNull();
	});

	it('tem "Ver na agenda" apontando para o dia local', () => {
		const { getByRole } = render(AuditEntry, { props: { entry: entry(), timezone: TZ } });
		expect(getByRole('link', { name: /Ver na agenda/ })).toHaveAttribute('href', '/agenda?date=2026-07-20');
	});

	// O `record_id` sempre existiu na API e no load; o que faltava era ENTRADA para ele — sem
	// este link, só chegava ao histórico de um registro quem digitasse a URL à mão.
	it('tem "Ver histórico" isolando o registro', () => {
		const { getByRole } = render(AuditEntry, { props: { entry: entry(), timezone: TZ } });
		expect(getByRole('link', { name: /Ver histórico/ })).toHaveAttribute(
			'href',
			'/auditoria?record_id=a1'
		);
	});

	// O link de histórico NÃO carrega mais o recurso: `record_id` é um uuid, único no sistema, e o
	// feed unificado (doc 63) mostra a vida do registro sem precisar saber de que tipo ele é.
	it('o link de histórico isola o registro, sem precisar do recurso', () => {
		const { getByRole } = render(AuditEntry, {
			props: {
				entry: entry({ resource: 'attendance', action: 'create', action_type: 'create', record_id: 'at1' }),
				timezone: TZ
			}
		});
		expect(getByRole('link', { name: /Ver histórico/ })).toHaveAttribute(
			'href',
			'/auditoria?record_id=at1'
		);
	});

	// A regressão que originou o redesenho: "Fulano entrou na turma · Mariana" dizia que quem
	// entrou foi o Fulano. O paciente é OBJETO da frase, e o ator é sujeito.
	it('participante: verbo de ator, paciente como objeto, sem "turma"', () => {
		const { getByRole, getByText } = render(AuditEntry, {
			props: {
				entry: entry({
					resource: 'attendance',
					action: 'create',
					action_type: 'create',
					patient: { id: 'pac1', nome: 'Mariana Alves' }
				}),
				timezone: TZ
			}
		});
		const titulo = getByRole('heading', { name: 'Adicionou Mariana Alves ao atendimento' });
		expect(titulo).toBeInTheDocument();
		expect(titulo.textContent).not.toMatch(/turma/i);
		// O ator NÃO é o sujeito da frase — ele está na linha de baixo.
		expect(getByText('por Ana Gestora')).toBeInTheDocument();
	});

	// A API passou a enriquecer a versão de presença com o bloco (starts_at + profissional).
	it('participante agora também leva contexto e link de agenda', () => {
		const { getByRole, getByText } = render(AuditEntry, {
			props: {
				entry: entry({
					resource: 'attendance',
					action: 'mark_present',
					patient: { id: 'pac1', nome: 'Mariana Alves' },
					diff: []
				}),
				timezone: TZ
			}
		});
		expect(getByText('Dra. Bea · seg 20/07, 08:00')).toBeInTheDocument();
		expect(getByRole('link', { name: /Ver na agenda/ })).toBeInTheDocument();
	});

	it('sem o bloco legível (excluído), some o contexto e o link de agenda', () => {
		const { queryByRole } = render(AuditEntry, {
			props: {
				entry: entry({ resource: 'attendance', meta: {}, professional: null, diff: [] }),
				timezone: TZ
			}
		});
		expect(queryByRole('link', { name: /Ver na agenda/ })).toBeNull();
	});

	it('sem autor, mostra "Sistema"', () => {
		const { getByText } = render(AuditEntry, { props: { entry: entry({ actor: null }), timezone: TZ } });
		expect(getByText('por Sistema')).toBeInTheDocument();
	});
});
