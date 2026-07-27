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
		['/relatorios', 'relatorios'],
		['/auditoria', 'auditoria'],
		['/notificacoes', 'notificacoes']
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

	it('a Auditoria é seção do rail, e a única restrita a owner·admin', () => {
		const aud = RAIL_ITEMS.find((i) => i.section === 'auditoria');
		expect(aud).toEqual({
			section: 'auditoria',
			label: 'Auditoria',
			href: '/auditoria',
			ownerAdmin: true
		});

		// Ela é a única restrita — os demais destinos são de todo membro (o Rail é que oculta).
		const restritos = RAIL_ITEMS.filter((i) => i.ownerAdmin).map((i) => i.href);
		expect(restritos).toEqual(['/auditoria']);
	});

	it('a Auditoria saiu de Configurações (nenhum ajuste aponta para ela)', () => {
		expect(CONFIG_LINKS.some((l) => l.href.includes('auditoria'))).toBe(false);
	});
});
