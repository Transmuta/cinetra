import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import RoleBadge from './RoleBadge.svelte';
import StatusBadge from './StatusBadge.svelte';

describe('RoleBadge', () => {
	it.each([
		['owner', 'Dona'],
		['admin', 'Administrador'],
		['profissional', 'Profissional'],
		['recepcao', 'Recepção']
	] as const)('papel %s mostra "%s"', (papel, label) => {
		const { getByText } = render(RoleBadge, { props: { papel } });
		expect(getByText(label)).toBeInTheDocument();
	});
});

describe('StatusBadge', () => {
	it('pendente → "Convite pendente"', () => {
		const { getByText } = render(StatusBadge, { props: { status: 'pendente' } });
		expect(getByText('Convite pendente')).toBeInTheDocument();
	});

	it('ativo → "Ativo"', () => {
		const { getByText } = render(StatusBadge, { props: { status: 'ativo' } });
		expect(getByText('Ativo')).toBeInTheDocument();
	});
});
