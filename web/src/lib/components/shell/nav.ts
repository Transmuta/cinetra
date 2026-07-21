// Modelo de navegação do shell administrativo (fiel ao protótipo: rail global + sidebar
// contextual). Sem Svelte aqui — os ícones são resolvidos nos componentes.

export type Section = 'agenda' | 'pacientes' | 'profissionais' | 'fila' | 'relatorios' | 'config';

export const SECTION_TITLES: Record<Section, string> = {
	agenda: 'Agenda',
	pacientes: 'Pacientes',
	profissionais: 'Profissionais',
	fila: 'Fila de espera',
	relatorios: 'Relatórios',
	config: 'Configurações'
};

// A qual seção o caminho atual pertence (para o destaque do rail e o título da sidebar).
export function sectionOf(pathname: string): Section | null {
	if (pathname.startsWith('/configuracoes')) return 'config';
	if (pathname.startsWith('/agenda')) return 'agenda';
	if (pathname.startsWith('/pacientes')) return 'pacientes';
	if (pathname.startsWith('/profissionais')) return 'profissionais';
	if (pathname.startsWith('/fila')) return 'fila';
	if (pathname.startsWith('/relatorios')) return 'relatorios';
	return null;
}

export interface RailItem {
	section: Section;
	label: string;
	href: string;
}

// Destinos do rail. Nesta fatia só Configurações → Equipe está construído; os demais
// levam a 404 de propósito (andaime de navegação).
export const RAIL_ITEMS: RailItem[] = [
	{ section: 'agenda', label: 'Agenda', href: '/agenda' },
	{ section: 'pacientes', label: 'Pacientes', href: '/pacientes' },
	{ section: 'profissionais', label: 'Profissionais', href: '/profissionais' },
	{ section: 'fila', label: 'Fila de espera', href: '/fila' },
	{ section: 'relatorios', label: 'Relatórios', href: '/relatorios' },
	{ section: 'config', label: 'Configurações', href: '/configuracoes' }
];

export interface ConfigLink {
	label: string;
	href: string;
	// Restrito a owner·admin (a Auditoria). O rail mostra o link só para quem pode entrar — a
	// autoridade real continua na policy da API (403). Ausente = visível a todo membro.
	ownerAdmin?: boolean;
}

// Sidebar de Configurações. Clínica (identidade), Tipos, Horário, Exceções, Equipe e Auditoria.
export const CONFIG_LINKS: ConfigLink[] = [
	{ label: 'Clínica', href: '/configuracoes/clinica' },
	{ label: 'Tipos de atendimento', href: '/configuracoes/tipos' },
	{ label: 'Horário', href: '/configuracoes/horario' },
	{ label: 'Exceções', href: '/configuracoes/excecoes' },
	{ label: 'Equipe & acessos', href: '/configuracoes/equipe' },
	{ label: 'Auditoria', href: '/configuracoes/auditoria', ownerAdmin: true }
];
