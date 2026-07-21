import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';
import { page } from '$app/state';
import Sidebar from './Sidebar.svelte';

describe('Sidebar', () => {
	it('em Configurações mostra a sub-nav de ajustes e o nome da clínica', () => {
		const { getByRole, getByText } = render(Sidebar, {
			props: { pathname: '/configuracoes/equipe', clinicName: 'Clínica Centro' }
		});
		expect(getByText('Clínica Centro')).toBeInTheDocument();
		expect(getByRole('link', { name: 'Clínica' })).toHaveAttribute('href', '/configuracoes/clinica');
		expect(getByRole('link', { name: 'Equipe & acessos' })).toHaveAttribute(
			'href',
			'/configuracoes/equipe'
		);
		expect(getByRole('link', { name: 'Tipos de atendimento' })).toHaveAttribute(
			'href',
			'/configuracoes/tipos'
		);
	});

	it('no topo mostra o nome da clínica (sem a marca Cinetra) com CNPJ mascarado e endereço', () => {
		const { getByText, queryByText } = render(Sidebar, {
			props: {
				pathname: '/agenda',
				clinicName: 'Clínica Vida',
				clinicCnpj: '12ABC34501DE35',
				clinicEndereco: 'Rua X, 100'
			}
		});
		expect(getByText('Clínica Vida')).toBeInTheDocument();
		expect(getByText('12.ABC.345/01DE-35')).toBeInTheDocument();
		expect(getByText('Rua X, 100')).toBeInTheDocument();
		// o nome substitui a logomarca: "Cinetra" não aparece no sidebar (vive no rail).
		expect(queryByText('Cinetra')).toBeNull();
	});

	it('sem nome de clínica, cai na marca Cinetra', () => {
		const { getByText } = render(Sidebar, { props: { pathname: '/agenda' } });
		expect(getByText('Cinetra')).toBeInTheDocument();
	});

	it('destaca a aba atual', () => {
		const { getByRole } = render(Sidebar, { props: { pathname: '/configuracoes/equipe' } });
		expect(getByRole('link', { name: 'Equipe & acessos' })).toHaveAttribute('aria-current', 'page');
		expect(getByRole('link', { name: 'Horário' })).not.toHaveAttribute('aria-current');
	});

	it('fora de Configurações não renderiza a sub-nav', () => {
		const { queryByRole } = render(Sidebar, { props: { pathname: '/agenda' } });
		expect(queryByRole('link', { name: 'Equipe & acessos' })).toBeNull();
	});
});

// A Auditoria é owner·admin: o link do rail só aparece para quem pode entrar (a policy da API
// é a autoridade — os demais levariam 403). O papel vem de `page.data.me`.
describe('Sidebar — Auditoria (owner·admin)', () => {
	afterEach(() => {
		for (const k of Object.keys(page.data)) delete (page.data as Record<string, unknown>)[k];
	});

	function renderConfig(papel: string | null) {
		Object.assign(page.data, { me: papel ? { papel } : null });
		return render(Sidebar, { props: { pathname: '/configuracoes/equipe' } });
	}

	it('owner vê o link de Auditoria', () => {
		expect(renderConfig('owner').getByRole('link', { name: 'Auditoria' })).toHaveAttribute(
			'href',
			'/configuracoes/auditoria'
		);
	});

	it('admin vê o link de Auditoria', () => {
		expect(renderConfig('admin').getByRole('link', { name: 'Auditoria' })).toBeInTheDocument();
	});

	it('recepção NÃO vê o link (mas vê os demais ajustes)', () => {
		const { queryByRole, getByRole } = renderConfig('recepcao');
		expect(queryByRole('link', { name: 'Auditoria' })).toBeNull();
		expect(getByRole('link', { name: 'Equipe & acessos' })).toBeInTheDocument();
	});

	it('profissional NÃO vê o link', () => {
		expect(renderConfig('profissional').queryByRole('link', { name: 'Auditoria' })).toBeNull();
	});
});

// Ramo novo da Agenda (doc 25 §6). No protótipo `sbAgenda()` é o ramo `default:` de
// `sidebarBody` [:1407]; aqui ele é explícito por DECISÃO, não por transcrição — um
// `default` silencioso faria qualquer seção futura herdar a sidebar da agenda.
describe('Sidebar — Agenda', () => {
	const professionals = [
		{ id: 'p1', nome: 'Dra. Ana Souza', cor_indice: 1 },
		{ id: 'p2', nome: 'Dr. Bruno Lima', cor_indice: 2 }
	];

	// O ramo lê `page.data` (como Profissionais e Pacientes já fazem), então o teste injeta
	// os dados por lá.
	function renderAgenda(data: Record<string, unknown> = {}) {
		Object.assign(page.data, {
			professionals,
			hidden: [],
			date: '2026-07-20',
			me: { papel: 'recepcao' },
			...data
		});
		return render(Sidebar, { props: { pathname: '/agenda' } });
	}

	afterEach(() => {
		for (const k of Object.keys(page.data)) delete (page.data as Record<string, unknown>)[k];
	});

	it('lista os profissionais da clínica', () => {
		const { getByText } = renderAgenda();
		expect(getByText('Dra. Ana Souza')).toBeInTheDocument();
		expect(getByText('Dr. Bruno Lima')).toBeInTheDocument();
	});

	it('quem está visível pode ser ocultado, preservando a data na URL', () => {
		const { getByRole } = renderAgenda();
		const link = getByRole('link', { name: 'Ocultar Dra. Ana Souza' });
		expect(link).toHaveAttribute('href', '/agenda?date=2026-07-20&profs=p1');
	});

	it('quem está oculto pode voltar', () => {
		const { getByRole } = renderAgenda({ hidden: ['p1'] });
		expect(getByRole('link', { name: 'Mostrar Dra. Ana Souza' })).toHaveAttribute(
			'href',
			'/agenda?date=2026-07-20'
		);
	});

	it('ocultar um segundo profissional soma ao que já estava oculto', () => {
		const { getByRole } = renderAgenda({ hidden: ['p1'] });
		expect(getByRole('link', { name: 'Ocultar Dr. Bruno Lima' })).toHaveAttribute(
			'href',
			'/agenda?date=2026-07-20&profs=p1,p2'
		);
	});

	it('"Mostrar todos" só aparece quando há alguém oculto', () => {
		expect(renderAgenda().queryByRole('link', { name: 'Mostrar todos' })).toBeNull();
		cleanup();
		expect(
			renderAgenda({ hidden: ['p1'] }).getByRole('link', { name: 'Mostrar todos' })
		).toHaveAttribute('href', '/agenda?date=2026-07-20');
	});

	it('clínica sem profissional avisa em vez de mostrar lista vazia', () => {
		const { getByText } = renderAgenda({ professionals: [] });
		expect(getByText('Nenhum profissional cadastrado.')).toBeInTheDocument();
	});

	it('fora da Agenda o ramo não aparece', () => {
		Object.assign(page.data, { professionals, hidden: [], date: '2026-07-20' });
		const { queryByText } = render(Sidebar, { props: { pathname: '/pacientes' } });
		expect(queryByText('Dra. Ana Souza')).toBeNull();
	});
});
