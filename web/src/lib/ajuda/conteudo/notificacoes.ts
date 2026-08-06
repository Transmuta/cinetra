import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;

export const NOTIFICACOES: readonly Topico[] = [
	{
		id: 'o-sino',
		secao: 'notificacoes',
		titulo: 'O sino: o que a equipe é avisada',
		resumo: 'As notificações internas — nada disso vai para o paciente.',
		papeis: TODOS,
		roteiro82: '§10',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O sino, no pé da barra escura, guarda os avisos internos da clínica. O número em cima dele é quanto ainda não foi lido.'
			},
			{
				tipo: 'lista',
				itens: [
					'Atendimento marcado, remarcado ou cancelado.',
					'Falta registrada e entrada de participante numa turma.',
					'Ajuste ou cancelamento de um pacote inteiro.',
					'Vaga que abriu e paciente urgente na fila de espera.',
					'Mudança na equipe: alguém entrou, mudou de papel ou saiu.',
					'O resumo do dia seguinte, no fim da tarde, e o aviso de sessão em 15 minutos.',
					'O paciente respondeu que precisa remarcar.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Cada pessoa tem a própria caixa: você não lê as notificações de outra, e ninguém lê as suas.'
			}
		],
		vejaTambem: ['caixa-de-notificacoes', 'fila-vaga-aberta']
	},

	{
		id: 'caixa-de-notificacoes',
		secao: 'notificacoes',
		titulo: 'Ler, filtrar e limpar',
		resumo: 'A caixa cheia volta a ser útil em dois cliques.',
		papeis: TODOS,
		roteiro82: '§10',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Clique no sino para abrir a caixa.',
						print: 'notificacoes-01',
						alt: 'Caixa de notificações, com a lista de avisos e o filtro na lateral.'
					},
					{
						texto:
							'Na lateral, alterne entre "Todas" e "Não lidas". A segunda é a que serve no dia a dia.'
					},
					{
						texto:
							'Clique numa notificação para ir direto ao que ela fala — o atendimento, a fila, a equipe.'
					},
					{
						texto:
							'O botão de marcar como lida limpa o contador sem abrir. "Limpar" esvazia a caixa de uma vez.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Notificação antiga é removida sozinha depois de um tempo. A caixa é um mural do que está acontecendo, não um arquivo — para saber quem fez o quê meses atrás, o lugar é a Auditoria.'
			}
		],
		vejaTambem: ['o-sino', 'quem-mexeu-no-que']
	}
];
