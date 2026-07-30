import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';
import FieldDiff from './FieldDiff.svelte';

const TZ = 'America/Sao_Paulo';

afterEach(cleanup);

describe('FieldDiff', () => {
	it('mostra o rótulo do campo e o de→para já formatados', () => {
		const { getByText } = render(FieldDiff, {
			props: {
				resource: 'appointment',
				timezone: TZ,
				diff: [{ field: 'status', from: 'agendado', to: 'cancelado' }]
			}
		});
		expect(getByText('Situação:')).toBeInTheDocument();
		expect(getByText('Agendado')).toBeInTheDocument();
		expect(getByText('Cancelado')).toBeInTheDocument();
	});

	it('formata datas no fuso da clínica', () => {
		const { getByText } = render(FieldDiff, {
			props: {
				resource: 'appointment',
				timezone: TZ,
				diff: [{ field: 'starts_at', from: '2026-07-20T11:00:00Z', to: '2026-07-20T12:00:00Z' }]
			}
		});
		expect(getByText('20/07/2026 08:00')).toBeInTheDocument();
		expect(getByText('20/07/2026 09:00')).toBeInTheDocument();
	});

	it('diff vazio não renderiza lista', () => {
		const { container } = render(FieldDiff, {
			props: { resource: 'appointment', timezone: TZ, diff: [] }
		});
		expect(container.querySelector('ul')).toBeNull();
	});
});
