import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';

import AccessMatrixTable from './AccessMatrixTable.svelte';
import type { AccessMatrixData } from '$lib/access-matrix';

// A matriz é dado do backend; o que a tabela deve garantir é a tradução fiel: papéis com o
// rótulo de fonte única (ROLE_META), níveis com o rótulo ESCRITO (nunca só cor), e a obs da
// linha visível — é nela que moram as exceções (anexos, agenda própria).
const matrix: AccessMatrixData = {
	papeis: ['owner', 'admin', 'profissional', 'recepcao'],
	areas: [
		{
			id: 'anexos',
			label: 'Anexos do paciente',
			obs: 'A única exceção ao D16: profissional não vê anexos.',
			acesso: { owner: 'total', admin: 'total', profissional: 'nao', recepcao: 'total' }
		},
		{
			id: 'agenda',
			label: 'Agenda e presenças',
			obs: null,
			acesso: { owner: 'total', admin: 'total', profissional: 'propria', recepcao: 'total' }
		}
	]
};

describe('AccessMatrixTable', () => {
	it('cabeçalho usa os rótulos de fonte única dos papéis', () => {
		render(AccessMatrixTable, { props: { matrix } });
		for (const label of ['Dono(a)', 'Administrador', 'Profissional', 'Recepção']) {
			expect(screen.getByRole('columnheader', { name: label })).toBeInTheDocument();
		}
	});

	it('cada célula escreve o nível (não é só cor)', () => {
		render(AccessMatrixTable, { props: { matrix } });
		expect(screen.getAllByText('Vê e altera').length).toBeGreaterThan(0);
		expect(screen.getByText('Sem acesso')).toBeInTheDocument();
		expect(screen.getByText('Só o próprio')).toBeInTheDocument();
	});

	it('a observação da linha fica visível — é onde mora a exceção', () => {
		render(AccessMatrixTable, { props: { matrix } });
		expect(screen.getByText(/profissional não vê anexos/)).toBeInTheDocument();
	});
});
