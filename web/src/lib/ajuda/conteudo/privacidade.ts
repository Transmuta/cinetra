import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;

export const PRIVACIDADE: readonly Topico[] = [
	{
		id: 'quem-ve-os-dados',
		secao: 'privacidade',
		titulo: 'Quem enxerga os dados da sua clínica',
		resumo: 'O isolamento entre clínicas e o que o papel de cada um alcança.',
		papeis: TODOS,
		roteiro82: '§15',
		blocos: [
			{
				tipo: 'lista',
				itens: [
					'Cada clínica é um espaço fechado. Quem é de outra clínica não enxerga nada da sua — nem por link, nem por busca.',
					'Dentro da clínica, o papel decide o alcance: o profissional não vê anexos, e configurações e auditoria ficam com a direção.',
					'Toda abertura de anexo e toda alteração relevante ficam registradas na trilha de auditoria, com autor e horário.'
				]
			},
			{
				tipo: 'texto',
				texto:
					'A equipe da Cinetra não acessa dados de pacientes na rotina. Quando um acesso é necessário para suporte técnico, ele acontece a pedido da clínica e fica registrado.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'A forma mais eficaz de proteger a clínica é a higiene de acessos: remova quem saiu, revise papéis de vez em quando e não compartilhe sessão entre pessoas.'
			}
		],
		vejaTambem: ['os-quatro-papeis', 'quem-mexeu-no-que', 'gerenciar-acessos']
	},

	{
		id: 'pedidos-do-paciente-lgpd',
		secao: 'privacidade',
		titulo: 'Pedidos do paciente sobre os dados dele',
		resumo: 'O que fazer quando alguém pede cópia, correção ou exclusão.',
		papeis: ['owner', 'admin'],
		roteiro82: '§15',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Quem responde ao paciente é a clínica: os dados são dela, e o Cinetra é a ferramenta onde eles ficam. Os pedidos mais comuns têm caminho direto no sistema.'
			},
			{
				tipo: 'tabela',
				colunas: ['O paciente pede', 'O caminho'],
				linhas: [
					['Ver ou corrigir os dados dele', 'Ficha do paciente → "Editar dados"'],
					['Parar de receber mensagens', 'Ficha do paciente → consentimentos, ou o link de saída da própria mensagem'],
					['Sair da lista de atendimento', 'Ficha do paciente → "Arquivar"'],
					['Cópia dos documentos que entregou', 'Ficha do paciente → "Anexos e documentos"']
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Apagar tudo raramente é o certo: registro de atendimento em saúde tem prazo legal de guarda. Antes de excluir qualquer coisa em definitivo, confirme o prazo aplicável ao seu caso — arquivar atende à maior parte dos pedidos sem quebrar essa obrigação.'
			}
		],
		vejaTambem: ['arquivar-e-reativar', 'descadastro-do-paciente', 'termos-e-privacidade']
	},

	{
		id: 'termos-e-privacidade',
		secao: 'privacidade',
		titulo: 'Termos de uso e política de privacidade',
		resumo: 'Onde ler os documentos e o que eles cobrem.',
		papeis: TODOS,
		roteiro82: '§15',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Os dois documentos ficam abertos no site, sem precisar de login, e descrevem o que o sistema realmente faz: quais dados são tratados, com quem são compartilhados, por quanto tempo ficam guardados e como exercer os direitos previstos na LGPD.'
			},
			{
				tipo: 'lista',
				itens: [
					'Política de privacidade: o tratamento dos dados, ponto a ponto.',
					'Termos de uso: as regras do serviço, incluindo disponibilidade e suporte.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Os documentos trazem a data da última atualização no topo. Vale conferi-la quando alguém da clínica perguntar se algo mudou.'
			}
		],
		vejaTambem: ['quem-ve-os-dados', 'pedidos-do-paciente-lgpd']
	}
];
