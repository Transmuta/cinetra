// Modelo de navegação do shell administrativo (fiel ao protótipo: rail global + sidebar
// contextual). Sem Svelte aqui — os ícones são resolvidos nos componentes.

// `notificacoes` é seção **sem item de rail**: o acesso é o sino no rodapé do rail, não um
// ícone da lista. Ela existe aqui porque a caixa tem sidebar contextual própria (os filtros
// Todas/Não lidas), e é `sectionOf` quem decide qual ramo da sidebar renderiza.
export type Section =
	| 'agenda'
	| 'pacientes'
	| 'profissionais'
	| 'fila'
	| 'relatorios'
	| 'auditoria'
	| 'config'
	| 'notificacoes';

export const SECTION_TITLES: Record<Section, string> = {
	agenda: 'Agenda',
	pacientes: 'Pacientes',
	profissionais: 'Profissionais',
	fila: 'Fila de espera',
	relatorios: 'Relatórios',
	auditoria: 'Auditoria',
	config: 'Configurações',
	notificacoes: 'Notificações'
};

// A qual seção o caminho atual pertence (para o destaque do rail e o título da sidebar).
export function sectionOf(pathname: string): Section | null {
	if (pathname.startsWith('/configuracoes')) return 'config';
	if (pathname.startsWith('/notificacoes')) return 'notificacoes';
	if (pathname.startsWith('/agenda')) return 'agenda';
	if (pathname.startsWith('/pacientes')) return 'pacientes';
	if (pathname.startsWith('/profissionais')) return 'profissionais';
	if (pathname.startsWith('/fila')) return 'fila';
	if (pathname.startsWith('/relatorios')) return 'relatorios';
	if (pathname.startsWith('/auditoria')) return 'auditoria';
	return null;
}

export interface RailItem {
	section: Section;
	label: string;
	href: string;
	// Restrito a owner·admin (a Auditoria). O rail mostra o item só para quem pode entrar — a
	// autoridade real continua na policy da API (403). Ausente = visível a todo membro.
	ownerAdmin?: boolean;
}

// Destinos do rail. Todas as seções abaixo já têm tela construída; nenhuma é mais andaime/404.
//
// A Auditoria é seção de primeiro nível, e não um item de Configurações: ela não AJUSTA nada —
// é uma tela de consulta, com filtros próprios e a maior tabela do sistema por trás. Enterrada
// em `/configuracoes/auditoria`, custava dois cliques e não tinha onde pendurar os filtros.
export const RAIL_ITEMS: RailItem[] = [
	{ section: 'agenda', label: 'Agenda', href: '/agenda' },
	{ section: 'pacientes', label: 'Pacientes', href: '/pacientes' },
	{ section: 'profissionais', label: 'Profissionais', href: '/profissionais' },
	{ section: 'fila', label: 'Fila de espera', href: '/fila' },
	{ section: 'relatorios', label: 'Relatórios', href: '/relatorios' },
	{ section: 'auditoria', label: 'Auditoria', href: '/auditoria', ownerAdmin: true },
	{ section: 'config', label: 'Configurações', href: '/configuracoes' }
];

export interface ConfigLink {
	label: string;
	href: string;
}

// Sidebar de Configurações. Clínica (identidade), Tipos, Horário, Exceções e Equipe — a
// Auditoria saiu daqui e virou seção do rail.
export const CONFIG_LINKS: ConfigLink[] = [
	{ label: 'Clínica', href: '/configuracoes/clinica' },
	{ label: 'Tipos de atendimento', href: '/configuracoes/tipos' },
	{ label: 'Horário', href: '/configuracoes/horario' },
	{ label: 'Exceções', href: '/configuracoes/excecoes' },
	{ label: 'Equipe & acessos', href: '/configuracoes/equipe' }
];
