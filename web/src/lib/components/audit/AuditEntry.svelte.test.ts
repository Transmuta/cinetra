import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';
import AuditEntry from './AuditEntry.svelte';
import type { AuditEntry as Entry } from '$lib/audit';

const TZ = 'America/Sao_Paulo';

function entry(over: Partial<Entry> = {}): Entry {
	return {
		id: 'v1',
		resource: 'appointment',
		record_id: 'a1',
		action: 'cancel',
		action_type: 'update',
		at: '2026-07-20T14:30:00Z',
		status: 'cancelado',
		actor: { id: 'u1', nome: 'Ana Gestora' },
		starts_at: '2026-07-20T11:00:00Z',
		professional: { id: 'p1', nome: 'Dra. Bea' },
		patient: null,
		appointment_id: null,
		diff: [{ field: 'status', from: 'agendado', to: 'cancelado' }],
		...over
	};
}

afterEach(cleanup);

describe('AuditEntry', () => {
	it('mostra quem, a ação, o contexto e o quando', () => {
		const { getByText } = render(AuditEntry, { props: { entry: entry(), timezone: TZ } });
		expect(getByText('Ana Gestora')).toBeInTheDocument();
		expect(getByText('cancelou')).toBeInTheDocument();
		expect(getByText('Dra. Bea')).toBeInTheDocument();
		expect(getByText('20/07/2026 11:30')).toBeInTheDocument(); // `at` no fuso da clínica
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

	it('agendamento tem "Ver na agenda" apontando para o dia local', () => {
		const { getByRole } = render(AuditEntry, { props: { entry: entry(), timezone: TZ } });
		expect(getByRole('link', { name: /Ver na agenda/ })).toHaveAttribute('href', '/agenda?date=2026-07-20');
	});

	it('participante (attendance) mostra o paciente e não tem link de agenda', () => {
		const { getByText, queryByRole } = render(AuditEntry, {
			props: {
				entry: entry({
					resource: 'attendance',
					action: 'create',
					action_type: 'create',
					starts_at: null,
					professional: null,
					patient: { id: 'pac1', nome: 'Caio Paciente' }
				}),
				timezone: TZ
			}
		});
		expect(getByText('Caio Paciente')).toBeInTheDocument();
		expect(queryByRole('link', { name: /Ver na agenda/ })).toBeNull();
	});

	it('sem autor, mostra "Sistema"', () => {
		const { getByText } = render(AuditEntry, { props: { entry: entry({ actor: null }), timezone: TZ } });
		expect(getByText('Sistema')).toBeInTheDocument();
	});
});
