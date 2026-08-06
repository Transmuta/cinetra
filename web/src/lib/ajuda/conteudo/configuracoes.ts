import type { Topico } from '../tipos';

const GESTAO = ['owner', 'admin'] as const;

export const CONFIGURACOES: readonly Topico[] = [
	{
		id: 'dados-da-clinica',
		secao: 'configuracoes',
		titulo: 'Os dados da clínica',
		resumo: 'Nome, CNPJ, telefone e endereço — o que aparece para o paciente.',
		papeis: GESTAO,
		roteiro82: '§3',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Vá em Configurações → Clínica.',
						print: 'config-clinica-01',
						alt: 'Tela de dados da clínica, com nome, CNPJ, telefone e endereço.'
					},
					{
						texto:
							'O nome é o que a equipe vê no menu de clínicas e o que entra nas mensagens ao paciente. Vale usar o nome pelo qual a clínica é conhecida.'
					},
					{
						texto:
							'O CNPJ é conferido enquanto você digita: número inválido é recusado antes de salvar.'
					},
					{ texto: 'Salve. A mudança vale na hora para toda a equipe.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto: 'Só dono e administrador editam esta tela. Os demais a veem em modo de leitura.'
			}
		],
		vejaTambem: ['roteiro-do-primeiro-dia', 'o-que-o-paciente-recebe']
	},

	{
		id: 'tipos-de-atendimento',
		secao: 'configuracoes',
		titulo: 'Tipos de atendimento',
		resumo: 'A duração, a cor e o nome do que a clínica faz.',
		papeis: GESTAO,
		roteiro82: '§3',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O tipo é o que responde "quanto tempo dura?" e "de que cor é?" na agenda. A clínica nasce com cinco prontos; ajuste-os em vez de criar tudo do zero.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Vá em Configurações → Tipos de atendimento.',
						print: 'config-tipos-01',
						alt: 'Lista dos tipos de atendimento da clínica, com duração e cor de cada um.'
					},
					{
						texto:
							'Clique no lápis para editar um tipo, ou em "Novo tipo" para criar. Nome e duração são o essencial.',
						print: 'config-tipos-02',
						alt: 'Formulário do tipo de atendimento, com nome, duração, cor, ícone e a opção de grupo.'
					},
					{
						texto:
							'A duração vira o tamanho do bloco na agenda. Trocar a duração aqui não mexe no que já está marcado — só no que for marcado daqui para a frente.'
					},
					{
						texto:
							'A cor ajuda a ler a grade. Vale diferenciar avaliação de sessão, que é a distinção mais consultada no balcão.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Tipo que não se usa mais deve ser arquivado, não apagado: ele continua explicando os atendimentos antigos que o usaram.'
			}
		],
		vejaTambem: ['tipo-em-grupo', 'cores-e-ocupacao', 'marcar-um-atendimento']
	},

	{
		id: 'tipo-em-grupo',
		secao: 'configuracoes',
		titulo: 'Tipo em grupo: pilates, turma, hidro',
		resumo: 'Como um tipo passa a aceitar vários pacientes no mesmo horário.',
		papeis: GESTAO,
		roteiro82: '§3',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Edite o tipo e ligue a chave "Atendimento em grupo".',
						print: 'config-tipos-grupo-01',
						alt: 'Formulário do tipo com a chave de atendimento em grupo ligada e o campo de capacidade.'
					},
					{
						texto:
							'Defina a capacidade: quantas pessoas cabem na turma. É o limite que o formulário da agenda vai respeitar.'
					},
					{ texto: 'Salve.' }
				]
			},
			{
				tipo: 'texto',
				texto:
					'A partir daí, ao escolher esse tipo na agenda, o campo "Paciente" vira "Participantes", com o contador de vagas. E, no painel, cada participante ganha a própria linha de presença.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'A capacidade não precisa ser o máximo da sala. Use o número que você realmente quer atender junto — é ele que vai impedir a turma de estourar num dia corrido.'
			}
		],
		vejaTambem: ['turma-presenca-por-participante', 'tipos-de-atendimento']
	},

	{
		id: 'horario-de-funcionamento',
		secao: 'configuracoes',
		titulo: 'O horário de funcionamento',
		resumo: 'Os dias e as faixas em que a clínica atende.',
		papeis: GESTAO,
		roteiro82: '§3',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Este horário é a moldura de tudo: a grade da agenda é desenhada a partir dele, e nada é marcado fora dele.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Vá em Configurações → Horário.',
						print: 'config-horario-01',
						alt: 'Tela do horário de funcionamento, com os dias da semana e as faixas de atendimento.'
					},
					{
						texto:
							'Para cada dia, defina as faixas de atendimento. Duas faixas no mesmo dia é como se fecha para o almoço.'
					},
					{
						texto:
							'Dia sem faixa nenhuma é dia fechado — ele aparece assim na agenda, e não aceita marcação.'
					},
					{ texto: 'Salve. A grade se ajusta na hora.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Feriado e recesso não entram aqui: eles são exceções de data, para não bagunçar o horário normal da semana.'
			}
		],
		vejaTambem: ['excecoes', 'horario-do-profissional', 'horario-nao-aparece']
	},

	{
		id: 'excecoes',
		secao: 'configuracoes',
		titulo: 'Exceções: feriado, recesso, dia diferente',
		resumo: 'Fechar um dia específico ou dar a ele um horário próprio.',
		papeis: GESTAO,
		roteiro82: '§3',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Exceção é o ajuste de uma data. Ela vence o horário normal daquele dia — e só daquele dia.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Vá em Configurações → Exceções.',
						print: 'config-excecoes-01',
						alt: 'Tela de exceções da agenda, com o formulário e a lista de datas já cadastradas.'
					},
					{
						texto:
							'Escolha a data, dê um nome ("Natal", "recesso de julho") e diga se o dia fecha inteiro ou se tem horário especial.'
					},
					{
						texto:
							'A lista mostra o que está lançado: fechado o dia inteiro aparece em vermelho, horário especial em verde.'
					},
					{ texto: 'Para desfazer, use a lixeira na linha da exceção.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Fechar um dia não cancela o que já estava marcado nele. Lance a exceção e depois passe na agenda daquele dia para remarcar ou cancelar o que ficou.'
			},
			{
				tipo: 'texto',
				texto:
					'Férias de uma pessoa não são exceção da clínica: elas ficam no cadastro do profissional, em "Exceções de data". A clínica continua aberta, só aquela coluna não.'
			}
		],
		vejaTambem: ['horario-de-funcionamento', 'horario-do-profissional', 'horario-nao-aparece']
	}
];
