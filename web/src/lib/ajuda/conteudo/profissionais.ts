import type { Topico } from '../tipos';

const GESTAO = ['owner', 'admin'] as const;

export const PROFISSIONAIS: readonly Topico[] = [
	{
		id: 'cadastrar-profissional',
		secao: 'profissionais',
		titulo: 'Cadastrar um profissional',
		resumo: 'Quem atende, com que registro, em que cor e em que horário.',
		papeis: ['owner', 'admin', 'recepcao'],
		roteiro82: '§5',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Cada profissional cadastrado vira uma coluna na agenda. Sem pelo menos um, não há onde marcar atendimento.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Em Profissionais, clique em "Novo profissional".',
						print: 'profissionais-lista-01',
						alt: 'Lista de profissionais da clínica.'
					},
					{
						texto:
							'Preencha a identificação. O "nome de exibição" é o que aparece na agenda — costuma ser mais curto que o nome completo ("Dra. Marina").',
						print: 'profissionais-novo-01',
						alt: 'Formulário de cadastro de profissional, na seção de identificação.'
					},
					{
						texto:
							'Em "Dados profissionais e técnicos", informe o número de registro no conselho e as áreas de atuação.'
					},
					{
						texto:
							'Em "Cor & status", escolha a cor dele na agenda. Cores distintas entre quem atende no mesmo turno é o que deixa a grade legível de longe.',
						print: 'profissionais-cor-01',
						alt: 'Seleção da cor do profissional na agenda.'
					},
					{ texto: 'Salve. A coluna dele aparece na agenda na hora.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Cadastrar o profissional não dá acesso ao sistema para ele. São duas coisas separadas — o acesso vem do convite, em Equipe & acessos.'
			}
		],
		vejaTambem: ['horario-do-profissional', 'dar-acesso-ao-profissional', 'convidar-alguem']
	},

	{
		id: 'horario-do-profissional',
		secao: 'profissionais',
		titulo: 'O horário de cada profissional',
		resumo: 'Quando o horário dele é diferente do da clínica.',
		papeis: GESTAO,
		roteiro82: '§5',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Por padrão, todo profissional segue o horário da clínica. Só vale ajustar quem foge disso: quem atende três dias por semana, quem entra depois do almoço.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Abra o profissional e vá até "Horário de atendimento". A chave "Seguir o horário da clínica" começa ligada.',
						print: 'profissionais-horario-01',
						alt: 'Seção de horário do profissional, com a chave de seguir o horário da clínica.'
					},
					{
						texto:
							'Desligue a chave para abrir a grade dos dias da semana e definir as faixas em que ele atende.'
					},
					{
						texto:
							'Logo abaixo, "Exceções de data" cobre o caso pontual: férias, congresso, um sábado extra.'
					},
					{ texto: 'Salve. A agenda passa a recusar horário fora do que você definiu.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'O horário do profissional nunca amplia o da clínica. Se a clínica fecha às 18h, marcar às 19h é recusado mesmo que o profissional esteja disponível.'
			}
		],
		vejaTambem: ['horario-de-funcionamento', 'excecoes', 'horario-nao-aparece']
	},

	{
		id: 'dar-acesso-ao-profissional',
		secao: 'profissionais',
		titulo: 'Dar acesso ao profissional',
		resumo: 'Ligar a pessoa que atende à pessoa que entra no sistema.',
		papeis: GESTAO,
		roteiro82: '§5',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'São dois cadastros diferentes de propósito. O profissional existe na agenda mesmo sem nunca abrir o sistema — é comum em clínica onde só a recepção opera. Quando ele precisa ver a própria agenda, aí entra o convite.'
			},
			{
				tipo: 'passos',
				passos: [
					{ texto: 'Cadastre o profissional em Profissionais, se ainda não existir.' },
					{
						texto:
							'Vá em Configurações → Equipe & acessos e convide o e-mail dele com o papel "Profissional".'
					},
					{
						texto:
							'Ao aceitar o convite, ele entra e vê a agenda da clínica — com a dele em destaque.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Se o profissional também cuida da agenda dos colegas, o papel certo pode ser Administrador, e não Profissional. O papel descreve o que a pessoa faz no sistema, não a profissão dela.'
			}
		],
		vejaTambem: ['convidar-alguem', 'os-quatro-papeis', 'o-que-o-profissional-ve']
	},

	{
		id: 'o-que-o-profissional-ve',
		secao: 'profissionais',
		titulo: 'O que o profissional enxerga',
		resumo: 'A agenda dele, em modo de leitura — e o porquê.',
		papeis: ['profissional', 'owner', 'admin'],
		roteiro82: '§5',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Quem entra com o papel Profissional lê a própria agenda e as fichas dos pacientes, mas não opera: não marca, não remarca, não cancela e não registra presença.'
			},
			{
				tipo: 'lista',
				itens: [
					'A agenda abre normalmente, com todas as visões, mas o painel do atendimento vem sem o rodapé de ações.',
					'A ficha do paciente abre inteira — menos os anexos, que ficam com o balcão e a gestão.',
					'A fila de espera pode ser consultada; quem põe, tira e oferece vaga é o balcão.',
					'A área de Profissionais não aparece: nem o diretório dos colegas, nem a própria ficha com CPF, endereço e dados bancários.',
					'Auditoria, equipe e as telas de configuração também não aparecem. Horários e tipos podem ser lidos, não editados.',
					'Nos relatórios, ele vê apenas os próprios números.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'Isso é uma escolha de organização, não desconfiança: com uma porta só para mexer na agenda — a recepção —, ninguém remarca por cima de ninguém sem a clínica saber.'
			}
		],
		vejaTambem: ['os-quatro-papeis', 'nao-vejo-um-menu']
	},

	{
		id: 'inativar-profissional',
		secao: 'profissionais',
		titulo: 'Inativar um profissional',
		resumo: 'Quem saiu da clínica sai da agenda, sem apagar o passado.',
		papeis: GESTAO,
		roteiro82: '§5',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Abra o profissional, vá até "Cor & status" e desligue a chave "Profissional ativo".',
						print: 'profissionais-inativar-01',
						alt: 'Chave "Profissional ativo" na seção de cor e status.'
					},
					{
						texto:
							'Ele deixa de aparecer como opção ao marcar novos atendimentos e some da lista lateral da agenda.'
					},
					{
						texto:
							'O histórico continua: os atendimentos que ele fez seguem no histórico dos pacientes, com o nome dele.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Antes de inativar, confira se ele tem atendimentos marcados adiante. Eles não somem sozinhos — precisam ser remarcados para outra pessoa ou cancelados.'
			}
		],
		vejaTambem: ['remarcar-um-atendimento', 'cadastrar-profissional']
	}
];
