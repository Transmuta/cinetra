import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;
const BALCAO = ['owner', 'admin', 'recepcao'] as const;

export const FILA: readonly Topico[] = [
	{
		id: 'fila-o-que-e',
		secao: 'fila',
		titulo: 'Para que serve a fila de espera',
		resumo: 'Guardar quem quer horário — e achar quem cabe quando um vaga.',
		papeis: TODOS,
		roteiro82: '§7',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'A fila é a lista de quem quer atendimento e ainda não tem horário fixo. Ela resolve dois problemas: não perder o contato de quem ligou, e ter a quem oferecer quando alguém desmarca.'
			},
			{
				tipo: 'print',
				print: 'fila-lista-01',
				alt: 'Tela da fila de espera, com pacientes, prioridade, disponibilidade e tempo de espera.',
				legenda: 'A lista mostra há quanto tempo cada pessoa espera.'
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Estar na fila não reserva horário nenhum. A vaga só é de alguém quando o atendimento é criado — é por isso que a oferta termina em "Agendar", e não em "reservar".'
			}
		],
		vejaTambem: ['fila-adicionar', 'fila-vaga-aberta']
	},

	{
		id: 'fila-adicionar',
		secao: 'fila',
		titulo: 'Colocar um paciente na fila',
		resumo: 'Prioridade, profissional preferido e quando a pessoa consegue vir.',
		papeis: BALCAO,
		roteiro82: '§7',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Em Fila de espera, clique em "Adicionar à fila".',
						print: 'fila-adicionar-01',
						alt: 'Formulário de entrada na fila, com paciente, prioridade e profissionais preferidos.'
					},
					{
						texto:
							'Escolha o paciente e a prioridade: Urgente, Alta, Normal ou Baixa. A prioridade organiza a lista — quem é mais urgente aparece antes.'
					},
					{
						texto:
							'Marque os profissionais preferidos, se houver. Sem marcar nenhum, qualquer um serve.'
					},
					{
						texto:
							'Em "Disponibilidade do paciente", diga quando ele consegue vir: os dias da semana e as faixas de horário, ou uma data específica.',
						print: 'fila-adicionar-02',
						alt: 'Seção de disponibilidade, com dias da semana e faixas de horário.',
						legenda: 'É esta informação que faz o sistema saber quem cabe numa vaga que abriu.'
					},
					{ texto: 'Use a observação para o combinado ("só depois das 17h", "prefere a Marina").' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Vale o esforço de preencher a disponibilidade com cuidado: quanto mais precisa, menos ligação perdida quando abrir uma vaga.'
			}
		],
		vejaTambem: ['fila-vaga-aberta', 'fila-o-que-e', 'cadastrar-paciente']
	},

	{
		id: 'fila-vaga-aberta',
		secao: 'fila',
		titulo: 'Abriu uma vaga: quem cabe ali',
		resumo: 'Da desmarcação até o novo atendimento marcado.',
		papeis: BALCAO,
		roteiro82: '§7',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Quando um atendimento é cancelado ou o paciente falta, aquele horário volta a ser oferecível. A fila é onde você descobre para quem oferecer.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Na tela da fila, o alto mostra as vagas que abriram. Na linha de cada paciente, "Oferecer" abre a busca de horários compatíveis com ele.',
						print: 'fila-oferecer-01',
						alt: 'Modal de oferecer vaga, com a lista de horários livres compatíveis com o paciente.'
					},
					{
						texto:
							'A lista traz só o que serve: respeita a disponibilidade do paciente, os profissionais preferidos e o expediente. O horário que acabou de vagar vem marcado com ABRIU.'
					},
					{
						texto:
							'Ligue para o paciente. Se ele aceitar, escolha o horário na lista, confira o tipo de atendimento e clique em "Agendar".'
					},
					{
						texto:
							'O atendimento é criado na agenda e o paciente sai da fila, tudo de uma vez.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Se outra pessoa da equipe estiver com a oferta do mesmo paciente aberta, a tela avisa. Sem reserva, quem clicar em "Agendar" primeiro fica com a vaga — o aviso existe justamente para vocês não ligarem para o mesmo paciente ao mesmo tempo.'
			}
		],
		vejaTambem: ['fila-sair', 'excluir-ou-cancelar', 'horario-ocupado']
	},

	{
		id: 'fila-sair',
		secao: 'fila',
		titulo: 'Editar ou tirar alguém da fila',
		resumo: 'Quando muda a disponibilidade, ou quando a pessoa desiste.',
		papeis: BALCAO,
		roteiro82: '§7',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Na linha do paciente, o lápis abre a mesma tela de entrada — é por ali que se corrige prioridade e disponibilidade.'
					},
					{
						texto:
							'A lixeira tira a pessoa da fila. Use quando ela desistiu ou conseguiu atendimento em outro lugar.'
					},
					{
						texto:
							'Quem foi atendido não precisa ser removido à mão: converter a oferta em atendimento já tira da fila.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'A coluna "Espera" mostra há quanto tempo cada um está na fila. Se alguém está lá há muito tempo, quase sempre a disponibilidade dele está estreita demais — vale reconferir por telefone.'
			}
		],
		vejaTambem: ['fila-adicionar', 'fila-vaga-aberta']
	}
];
