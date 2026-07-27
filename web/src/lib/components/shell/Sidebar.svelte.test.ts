import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';
import { page } from '$app/state';
import Sidebar from './Sidebar.svelte';

// `page.url` é só-leitura no `$app/state` (é derivado do estado do router). Os filtros que moram
// na URL — os da Auditoria — precisam dela, então o teste a redefine na marra.
//
// `restoreUrl` NÃO é zelo: sem ele o `defineProperty` é **permanente**, e os ramos que leem a
// query (Notificações lê `?filtro=`, Relatórios lê `?period=`) passam a herdar a URL da
// Auditoria conforme a ordem dos testes. Quatro testes de Notificações ficaram vermelhos assim.
const urlOriginal = Object.getOwnPropertyDescriptor(page, 'url');

function setUrl(href: string) {
	Object.defineProperty(page, 'url', { value: new URL(href), configurable: true });
}

function restoreUrl() {
	if (urlOriginal) Object.defineProperty(page, 'url', urlOriginal);
}

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

// Os filtros da Auditoria (doc 25 §11.4). Três deles — período, ação e autor — existiam na API,
// no BFF e no load, e NENHUM controle os escrevia: a tela não tinha um filtro sequer. Aqui eles
// vivem, como em Profissionais/Pacientes/Fila/Relatórios: links, estado na URL.
//
// O RBAC (owner·admin) mora no RAIL, que é quem mostra ou some com o destino — ver Rail.svelte.test.
describe('Sidebar — Auditoria (filtros)', () => {
	afterEach(() => {
		for (const k of Object.keys(page.data)) delete (page.data as Record<string, unknown>)[k];
		restoreUrl();
	});

	function renderAudit(search = '') {
		setUrl(`http://x/auditoria${search}`);
		Object.assign(page.data, {
			me: { papel: 'owner' },
			autores: [{ id: 'u1', nome: 'Ana Gestora' }]
		});
		return render(Sidebar, { props: { pathname: '/auditoria' } });
	}

	it('oferece os quatro eixos', () => {
		const { getByText } = renderAudit();
		for (const titulo of ['Registro', 'Período', 'Ação', 'Autor']) {
			expect(getByText(titulo)).toBeInTheDocument();
		}
	});

	it('o período viaja na URL e o default fica limpo', () => {
		const { getByRole } = renderAudit();
		expect(getByRole('link', { name: 'Últimos 7 dias' })).toHaveAttribute(
			'href',
			'/auditoria?periodo=7d'
		);
		// "Todo o histórico" é o default: o link o remove da URL em vez de escrever `periodo=tudo`.
		expect(getByRole('link', { name: 'Todo o histórico' })).toHaveAttribute('href', '/auditoria');
	});

	it('marca o filtro ativo com aria-current', () => {
		const { getByRole } = renderAudit('?periodo=7d');
		expect(getByRole('link', { name: 'Últimos 7 dias' })).toHaveAttribute('aria-current', 'page');
		expect(getByRole('link', { name: 'Hoje' })).not.toHaveAttribute('aria-current');
	});

	// A armadilha: as duas tabelas de ação não se cruzam. Manter `acao=cancel` ao ir para
	// Participantes devolveria um feed legitimamente vazio, que lê como defeito.
	it('trocar de registro zera ação, registro e página', () => {
		const { getByRole } = renderAudit('?acao=cancel&record_id=a1&page=3');
		expect(getByRole('link', { name: 'Participantes' })).toHaveAttribute(
			'href',
			'/auditoria?resource=attendance'
		);
	});

	it('as ações oferecidas são as do recurso aberto', () => {
		const bloco = renderAudit();
		expect(bloco.getByRole('link', { name: 'Cancelou' })).toBeInTheDocument();
		expect(bloco.queryByRole('link', { name: 'Marcou presença' })).toBeNull();
		cleanup();

		const presenca = renderAudit('?resource=attendance');
		expect(presenca.getByRole('link', { name: 'Marcou presença' })).toBeInTheDocument();
		expect(presenca.queryByRole('link', { name: 'Cancelou' })).toBeNull();
	});

	it('o autor sai da equipe carregada pelo load', () => {
		const { getByRole } = renderAudit();
		expect(getByRole('link', { name: 'Ana Gestora' })).toHaveAttribute(
			'href',
			'/auditoria?autor=u1'
		);
	});

	it('fora da Auditoria o ramo não renderiza', () => {
		setUrl('http://x/agenda');
		const { queryByText } = render(Sidebar, { props: { pathname: '/agenda' } });
		expect(queryByText('Registro')).toBeNull();
	});

	// Achado do bate-volta: a Auditoria é a ÚNICA seção owner·admin, e era a única cuja sidebar
	// aparecia para quem não pode entrar — `sectionOf` decide o ramo pelo caminho, e o caminho
	// continua `/auditoria` na página de 403. Recepção via a barra de filtros inteira, cada
	// clique levando a outro 403. O mesmo predicado do rail governa os dois agora.
	it.each(['recepcao', 'profissional'] as const)(
		'%s não vê os filtros (a tela é owner·admin)',
		(papel) => {
			setUrl('http://x/auditoria');
			Object.assign(page.data, { me: { papel }, autores: [] });
			const { queryByText } = render(Sidebar, { props: { pathname: '/auditoria' } });
			expect(queryByText('Registro')).toBeNull();
			expect(queryByText('Período')).toBeNull();
		}
	);
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

// Ramo novo: os filtros da caixa saíram do corpo da página e viraram sidebar contextual, como
// em Profissionais/Pacientes/Fila. Mesma regra das outras seções — o estado mora na URL e o
// sidebar são links, não botões.
describe('Sidebar — Notificações', () => {
	afterEach(() => {
		for (const k of Object.keys(page.data)) delete (page.data as Record<string, unknown>)[k];
	});

	function renderNotif(data: Record<string, unknown> = {}) {
		Object.assign(page.data, { unread: 3, ...data });
		return render(Sidebar, { props: { pathname: '/notificacoes' } });
	}

	it('oferece os dois filtros, com o "não lidas" na query', () => {
		const { getByRole } = renderNotif();
		expect(getByRole('link', { name: /todas/i })).toHaveAttribute('href', '/notificacoes');
		expect(getByRole('link', { name: /não lidas/i })).toHaveAttribute(
			'href',
			'/notificacoes?filtro=nao-lidas'
		);
	});

	// O número vem do layout (`page.data.unread`), que roda em toda navegação — não do load da
	// página. É o mesmo número do badge do sino.
	it('mostra a contagem de não-lidas', () => {
		const { getByRole } = renderNotif({ unread: 7 });
		expect(getByRole('link', { name: /não lidas/i })).toHaveTextContent('7');
	});

	it('caixa em dia não mostra número nenhum', () => {
		const { getByRole } = renderNotif({ unread: 0 });
		expect(getByRole('link', { name: /não lidas/i })).not.toHaveTextContent('0');
	});

	// "Todas" fica SEM número de propósito: a API não conta o total da caixa (`count: false` —
	// custaria ler o recorte inteiro a cada abertura). Melhor sem número do que com um que
	// contasse só a página aberta.
	it('"Todas" não exibe contagem', () => {
		const { getByRole } = renderNotif({ unread: 7 });
		expect(getByRole('link', { name: /todas/i })).not.toHaveTextContent('7');
	});

	it('fora da seção o ramo não aparece', () => {
		Object.assign(page.data, { unread: 3 });
		const { queryByRole } = render(Sidebar, { props: { pathname: '/agenda' } });
		expect(queryByRole('link', { name: /não lidas/i })).toBeNull();
	});
});
