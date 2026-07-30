import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import PriorityBadge from './PriorityBadge.svelte';

afterEach(cleanup);

describe('PriorityBadge', () => {
	it('mostra o rótulo do nível', () => {
		render(PriorityBadge, { props: { prio: 'urgente' } });
		expect(screen.getByText('Urgente')).toBeInTheDocument();
	});

	// A cor é o hex fixo do protótipo (não token de tema) — vai inline no style. O jsdom serializa
	// a cor para rgb(); `toHaveStyle` normaliza os dois lados e compara pela mesma origem (o hex).
	it('pinta o fundo com a cor da prioridade', () => {
		render(PriorityBadge, { props: { prio: 'alta' } });
		expect(screen.getByText('Alta')).toHaveStyle({ background: '#F5A623' });
	});

	it('cada nível tem seu rótulo', () => {
		render(PriorityBadge, { props: { prio: 'baixa' } });
		expect(screen.getByText('Baixa')).toBeInTheDocument();
	});
});
