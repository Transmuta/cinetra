import { describe, it, expect } from 'vitest';
import {
	TYPE_COLORS,
	TYPE_ICONS,
	DEFAULT_CAPACIDADE,
	DEFAULT_COR,
	DEFAULT_DURACAO,
	DEFAULT_ICON,
	iconComponent,
	tint,
	splitByStatus,
	canManageAppointmentTypes,
	type AppointmentType
} from './appointment-types';
import type { Papel } from './session';

const tipo = (over: Partial<AppointmentType> = {}): AppointmentType => ({
	id: 't1',
	nome: 'Sessão',
	sigla: 'SES',
	duracao_minutos: 50,
	cor: '#0FB5A6',
	icon: 'Activity',
	grupo: false,
	capacidade: null,
	ativo: true,
	...over
});

describe('paletas fechadas', () => {
	// A paleta é validada com `one_of` no servidor (doc 20 §1); estes testes são o
	// contrato do lado do cliente — se divergirem, a tela oferece o que a API recusa.
	it('as 8 cores, verbatim do protótipo (:2391)', () => {
		expect(TYPE_COLORS).toEqual([
			'#0FB5A6',
			'#0072B2',
			'#009E73',
			'#CC79A7',
			'#7A52CC',
			'#D55E00',
			'#E69F00',
			'#2B7FFF'
		]);
	});

	it('os 10 ícones, verbatim do protótipo (:2390)', () => {
		expect(TYPE_ICONS).toEqual([
			'Activity',
			'ClipboardList',
			'StretchHorizontal',
			'Users',
			'RefreshCw',
			'HeartPulse',
			'Dumbbell',
			'Footprints',
			'Hand',
			'Bone'
		]);
	});

	it('os defaults do "Novo tipo" saem das paletas (:3229)', () => {
		expect(DEFAULT_COR).toBe('#0072B2');
		expect(TYPE_COLORS).toContain(DEFAULT_COR);
		expect(DEFAULT_ICON).toBe('Activity');
		expect(TYPE_ICONS).toContain(DEFAULT_ICON);
		expect(DEFAULT_DURACAO).toBe(50);
		expect(DEFAULT_CAPACIDADE).toBe(4);
	});
});

describe('iconComponent', () => {
	it('resolve todo nome da paleta para um componente', () => {
		for (const name of TYPE_ICONS) expect(iconComponent(name)).toBeTypeOf('function');
	});

	it('nome fora da paleta cai no default em vez de quebrar a tela', () => {
		expect(iconComponent('Foguete')).toBe(iconComponent(DEFAULT_ICON));
	});
});

describe('tint', () => {
	it('hex → rgba com o alfa pedido (:314)', () => {
		expect(tint('#0FB5A6', 0.14)).toBe('rgba(15,181,166,0.14)');
	});

	it('aceita hex sem "#" e em minúsculas', () => {
		expect(tint('0072b2', 0.5)).toBe('rgba(0,114,178,0.5)');
	});

	it('valor inválido vira transparent, não NaN no style (:314)', () => {
		expect(tint('', 0.14)).toBe('transparent');
		expect(tint('#GGGGGG', 0.14)).toBe('transparent');
		expect(tint('#abc', 0.14)).toBe('transparent');
	});

	it('cor ausente vira transparent — a API é tipada, o JSON dela não', () => {
		expect(tint(null as unknown as string, 0.14)).toBe('transparent');
	});
});

describe('splitByStatus', () => {
	const types = [
		tipo({ id: 'a', ativo: true }),
		tipo({ id: 'b', ativo: false }),
		tipo({ id: 'c', ativo: true })
	];

	it('separa ativos de arquivados preservando a ordem da API', () => {
		const { ativos, arquivados } = splitByStatus(types);
		expect(ativos.map((t) => t.id)).toEqual(['a', 'c']);
		expect(arquivados.map((t) => t.id)).toEqual(['b']);
	});

	it('lista vazia → dois vazios (a seção Arquivados nem aparece)', () => {
		expect(splitByStatus([])).toEqual({ ativos: [], arquivados: [] });
	});
});

describe('canManageAppointmentTypes', () => {
	it('owner e admin gerenciam o catálogo (T8)', () => {
		expect(canManageAppointmentTypes('owner')).toBe(true);
		expect(canManageAppointmentTypes('admin')).toBe(true);
	});

	it('profissional, recepção e sem papel só leem (T8)', () => {
		for (const papel of ['profissional', 'recepcao', null, undefined] as (Papel | null | undefined)[])
			expect(canManageAppointmentTypes(papel)).toBe(false);
	});
});
