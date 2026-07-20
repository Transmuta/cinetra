import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import MediaProbe from '$lib/testing/MediaProbe.svelte';

// O jsdom não implementa `matchMedia`. A sonda abaixo é o mínimo do contrato que o hook usa:
// `matches` + add/removeEventListener('change').
function stubMatchMedia(matches: boolean) {
	const listeners = new Set<(e: MediaQueryListEvent) => void>();

	const mql = {
		matches,
		addEventListener: (_: string, cb: (e: MediaQueryListEvent) => void) => listeners.add(cb),
		removeEventListener: (_: string, cb: (e: MediaQueryListEvent) => void) => listeners.delete(cb)
	};

	vi.stubGlobal(
		'matchMedia',
		vi.fn(() => mql)
	);

	return {
		listeners,
		emit: (valor: boolean) => {
			mql.matches = valor;
			listeners.forEach((cb) => cb({ matches: valor } as MediaQueryListEvent));
		}
	};
}

afterEach(() => vi.unstubAllGlobals());

describe('mediaQuery', () => {
	it('começa no valor corrente da query', () => {
		stubMatchMedia(true);
		render(MediaProbe, { props: { query: '(max-width: 859px)' } });
		expect(screen.getByTestId('matches')).toHaveTextContent('sim');
	});

	it('acompanha a mudança de viewport', async () => {
		const mm = stubMatchMedia(false);
		render(MediaProbe, { props: { query: '(max-width: 859px)' } });
		expect(screen.getByTestId('matches')).toHaveTextContent('não');

		mm.emit(true);
		await vi.waitFor(() => expect(screen.getByTestId('matches')).toHaveTextContent('sim'));
	});

	// Listener que sobrevive ao componente é vazamento — e a agenda monta e desmonta este hook
	// a cada navegação entre visões.
	it('solta o listener ao desmontar', () => {
		const mm = stubMatchMedia(false);
		const { unmount } = render(MediaProbe, {
			props: { query: '(max-width: 859px)' }
		});

		expect(mm.listeners.size).toBe(1);
		unmount();
		expect(mm.listeners.size).toBe(0);
	});

	// SSR e navegadores sem `matchMedia` caem no desktop, que é o render que não pisca para
	// quem está no desktop.
	it('sem matchMedia no ambiente, devolve false em vez de estourar', () => {
		vi.stubGlobal('matchMedia', undefined);
		render(MediaProbe, { props: { query: '(max-width: 859px)' } });
		expect(screen.getByTestId('matches')).toHaveTextContent('não');
	});
});
