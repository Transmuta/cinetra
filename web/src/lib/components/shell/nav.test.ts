import { describe, it, expect } from 'vitest';
import { sectionOf, SECTION_TITLES, RAIL_ITEMS, CONFIG_LINKS } from './nav';

describe('sectionOf', () => {
	it.each([
		['/configuracoes', 'config'],
		['/configuracoes/equipe', 'config'],
		['/configuracoes/tipos', 'config'],
		['/agenda', 'agenda'],
		['/pacientes', 'pacientes'],
		['/profissionais', 'profissionais'],
		['/fila', 'fila'],
		['/relatorios', 'relatorios']
	])('%s → %s', (path, section) => {
		expect(sectionOf(path)).toBe(section);
	});

	it('caminho desconhecido → null', () => {
		expect(sectionOf('/qualquer')).toBeNull();
	});
});

describe('modelo de navegação', () => {
	it('o rail tem uma seção Configurações apontando para /configuracoes', () => {
		const config = RAIL_ITEMS.find((i) => i.section === 'config');
		expect(config?.href).toBe('/configuracoes');
	});

	it('todo item do rail tem um título de seção', () => {
		for (const item of RAIL_ITEMS) {
			expect(SECTION_TITLES[item.section]).toBeTruthy();
		}
	});

	it('Auditoria é o último link de Configurações e é o único restrito a owner·admin', () => {
		expect(CONFIG_LINKS.at(-1)).toEqual({
			label: 'Auditoria',
			href: '/configuracoes/auditoria',
			ownerAdmin: true
		});

		// Ela é a única restrita — os demais ajustes são de todo membro (a Sidebar é que oculta).
		const restritos = CONFIG_LINKS.filter((l) => l.ownerAdmin).map((l) => l.href);
		expect(restritos).toEqual(['/configuracoes/auditoria']);
	});
});
