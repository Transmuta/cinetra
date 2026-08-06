import type { Topico } from '../tipos';

const GESTAO = ['owner', 'admin'] as const;

export const RELATORIOS: readonly Topico[] = [
	{
		id: 'os-numeros-da-clinica',
		secao: 'relatorios',
		titulo: 'Os números da clínica',
		resumo: 'Os cinco indicadores do topo e o que cada um conta.',
		papeis: ['owner', 'admin', 'profissional'],
		roteiro82: '§11',
		blocos: [
			{
				tipo: 'print',
				print: 'relatorios-01',
				alt: 'Tela de relatórios com os cinco indicadores no topo e o volume por dia abaixo.'
			},
			{
				tipo: 'tabela',
				colunas: ['Indicador', 'O que ele conta'],
				linhas: [
					[
						'Atendimentos',
						'Pessoas atendidas no período, sem as de sessões canceladas. Numa turma, cada participante conta um. Inclui o que ainda vai acontecer.'
					],
					['Concluídos', 'Participantes marcados como presentes.'],
					[
						'Taxa de falta',
						'Faltas divididas por concluídos mais faltas. Só entra o que já fechou — o futuro não conta.'
					],
					[
						'Cancelamentos',
						'Sessões canceladas no período. Aqui a conta é de blocos, não de pessoas.'
					],
					[
						'Ocupação',
						'Minutos ocupados sobre minutos de expediente. Não é sessões sobre vagas: uma sessão de 50 minutos pesa mais que uma de 30.'
					]
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'O ícone de informação ao lado de cada indicador abre a fórmula exata, dentro do sistema. Quando um número parecer estranho, comece por ali.'
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto: 'O profissional também abre esta tela, mas vê apenas os próprios números.'
			}
		],
		vejaTambem: ['volume-por-dia', 'registrar-presenca-e-falta']
	},

	{
		id: 'volume-por-dia',
		secao: 'relatorios',
		titulo: 'O volume por dia e por profissional',
		resumo: 'Onde o movimento se concentra, e de quem ele é.',
		papeis: ['owner', 'admin', 'profissional'],
		roteiro82: '§11',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Escolha o período na lateral. Em mês ou trimestre, o volume aparece como calendário; na semana, como linhas por dia; num dia só, por profissional.',
						print: 'relatorios-volume-01',
						alt: 'Calendário de volume por dia, com a intensidade de cada dia.'
					},
					{
						texto:
							'Ainda na lateral, filtre por profissional para ver a agenda de uma pessoa só.'
					},
					{
						texto:
							'Abaixo, a tabela por profissional traz volume, faltas e taxa de falta lado a lado.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'"Sem dados no período" quer dizer que não houve atendimento naquele recorte — não que o relatório falhou. Confira o período e o filtro de profissional antes de concluir outra coisa.'
			}
		],
		vejaTambem: ['os-numeros-da-clinica', 'cores-e-ocupacao']
	}
];
