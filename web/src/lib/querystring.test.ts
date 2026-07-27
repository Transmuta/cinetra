import { describe, it, expect, vi, beforeEach } from 'vitest';

const gotoMock = vi.fn();
vi.mock('$app/navigation', () => ({ goto: (...args: unknown[]) => gotoMock(...args) }));

const { patchQuery, hrefWithQuery, navigateQuery } = await import('./querystring');

describe('patchQuery', () => {
	it('acrescenta a chave nova preservando o que já estava', () => {
		const params = new URLSearchParams('q=ana&filter=ativo');
		expect(patchQuery(params, { page: '3' })).toBe('q=ana&filter=ativo&page=3');
	});

	it('null e string vazia REMOVEM a chave — é como a página 1 some da URL', () => {
		const params = new URLSearchParams('q=ana&page=4');
		expect(patchQuery(params, { page: null })).toBe('q=ana');
		expect(patchQuery(params, { q: '' })).toBe('page=4');
	});

	it('substitui o valor de uma chave que já existe', () => {
		const params = new URLSearchParams('page=2');
		expect(patchQuery(params, { page: '5' })).toBe('page=5');
	});

	it('devolve string vazia quando não sobra nada', () => {
		expect(patchQuery(new URLSearchParams('page=2'), { page: null })).toBe('');
	});
});

describe('hrefWithQuery', () => {
	it('junta base e query com "?" — e devolve a base pelada quando não há query', () => {
		const params = new URLSearchParams('q=ana');
		expect(hrefWithQuery('/pacientes', params, { page: '2' })).toBe('/pacientes?q=ana&page=2');
		expect(hrefWithQuery('/pacientes', params, { q: null })).toBe('/pacientes');
	});

	it('não deixa "?" órfão na URL — o que faria o link parecer outro para o roteador', () => {
		expect(hrefWithQuery('/fila', new URLSearchParams(''), {})).toBe('/fila');
	});
});

describe('navigateQuery', () => {
	beforeEach(() => gotoMock.mockClear());

	// O I68: paginar é REFINAR a mesma tela. Sem `replaceState`, cada clique em "próxima" vira uma
	// entrada no histórico e sair da tela passa a exigir um "voltar" por página folheada.
	it('navega substituindo a entrada de histórico, sem rolar nem perder o foco', () => {
		navigateQuery('/configuracoes/auditoria', new URLSearchParams('resource=attendance'), {
			page: '3'
		});

		expect(gotoMock).toHaveBeenCalledWith('/configuracoes/auditoria?resource=attendance&page=3', {
			keepFocus: true,
			noScroll: true,
			replaceState: true
		});
	});
});
