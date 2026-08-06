import type { Secao, SecaoId } from './tipos';

/**
 * As seções da central, na ordem do índice — que é a ordem de quem está aprendendo, não a ordem
 * do menu do sistema. Primeiros passos vem antes de tudo; "Quando algo dá errado" vem por último
 * porque é onde se cai, não por onde se começa.
 */
export const SECOES: readonly Secao[] = [
	{
		id: 'primeiros-passos',
		titulo: 'Primeiros passos',
		resumo: 'Criar a conta, entrar, montar a clínica e reconhecer a tela.'
	},
	{
		id: 'agenda',
		titulo: 'Agenda',
		resumo: 'Marcar, remarcar, registrar presença e falta — o dia a dia da recepção.'
	},
	{
		id: 'pacientes',
		titulo: 'Pacientes',
		resumo: 'Cadastro, ficha, histórico e anexos.'
	},
	{
		id: 'profissionais',
		titulo: 'Profissionais',
		resumo: 'Cadastro, horário de atendimento e o que cada profissional enxerga.'
	},
	{
		id: 'configuracoes',
		titulo: 'Configurações da clínica',
		resumo: 'Tipos de atendimento, horário de funcionamento e exceções.'
	},
	{
		id: 'equipe',
		titulo: 'Equipe e acessos',
		resumo: 'Convidar pessoas, escolher o papel de cada uma e entender o que cada papel vê.'
	},
	{
		id: 'fila',
		titulo: 'Fila de espera',
		resumo: 'Guardar quem quer horário e ocupar a vaga que abriu.'
	},
	{
		id: 'pacotes',
		titulo: 'Pacotes de sessões',
		resumo: 'Vender e controlar um bloco de sessões sem marcar uma a uma.'
	},
	{
		id: 'comunicacao',
		titulo: 'Comunicação com o paciente',
		resumo: 'O que o paciente recebe, quando recebe e como conferir se chegou.'
	},
	{
		id: 'notificacoes',
		titulo: 'Notificações',
		resumo: 'O sino: o que a equipe é avisada dentro do sistema.'
	},
	{
		id: 'relatorios',
		titulo: 'Relatórios',
		resumo: 'Os números da clínica e o que cada um quer dizer.'
	},
	{
		id: 'auditoria',
		titulo: 'Auditoria',
		resumo: 'Quem mexeu no quê, e quando.'
	},
	{
		id: 'celular',
		titulo: 'No celular',
		resumo: 'Usar fora da recepção e instalar como aplicativo.'
	},
	{
		id: 'problemas',
		titulo: 'Quando algo dá errado',
		resumo: 'Os sintomas mais comuns, o motivo e a saída.'
	},
	{
		id: 'privacidade',
		titulo: 'Privacidade e dados',
		resumo: 'Quem enxerga os dados da clínica e o que fazer com pedidos do paciente.'
	}
];

export const SECAO_POR_ID: Record<SecaoId, Secao> = Object.fromEntries(
	SECOES.map((s) => [s.id, s])
) as Record<SecaoId, Secao>;
