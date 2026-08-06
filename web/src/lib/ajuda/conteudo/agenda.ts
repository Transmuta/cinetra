import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;
/** Quem mexe na agenda: dono, administrador e recepção. O profissional lê a dele. */
const BALCAO = ['owner', 'admin', 'recepcao'] as const;

export const AGENDA: readonly Topico[] = [
	{
		id: 'visoes-da-agenda',
		secao: 'agenda',
		titulo: 'As quatro visões da agenda',
		resumo: 'Dia, Semana, Mês e Lista — cada uma responde a uma pergunta diferente.',
		papeis: TODOS,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'No alto da agenda ficam as setas, o botão "Hoje", a data e o seletor de visão. As setas andam no passo da visão aberta: um dia, uma semana ou um mês.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Dia é a grade de horas, com uma coluna por profissional. É a visão do balcão: mostra buraco livre e sobreposição.',
						print: 'agenda-dia-01',
						alt: 'Visão Dia da agenda, com colunas por profissional e blocos coloridos ao longo das horas.'
					},
					{
						texto:
							'Semana mostra os sete dias lado a lado, com a barra de ocupação de cada um. Serve para achar onde ainda cabe alguém.',
						print: 'agenda-semana-01',
						alt: 'Visão Semana da agenda, com um dia por coluna.'
					},
					{
						texto:
							'Mês é o calendário: quantos atendimentos por dia e o quanto o dia está cheio. Serve para planejar, não para marcar.',
						print: 'agenda-mes-01',
						alt: 'Visão Mês da agenda, em formato de calendário.'
					},
					{
						texto:
							'Lista é o dia em texto, de cima para baixo. É a visão que se imprime e a que funciona melhor no celular.',
						print: 'agenda-lista-01',
						alt: 'Visão Lista da agenda, com um atendimento por linha.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'O botão "Hoje" fica destacado quando você já está no dia de hoje. É o jeito rápido de voltar depois de navegar longe.'
			}
		],
		vejaTambem: ['filtrar-por-profissional', 'cores-e-ocupacao', 'marcar-um-atendimento']
	},

	{
		id: 'filtrar-por-profissional',
		secao: 'agenda',
		titulo: 'Ver só alguns profissionais',
		resumo: 'Esconder colunas para enxergar a agenda de quem interessa.',
		papeis: TODOS,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Na coluna à esquerda da agenda ficam os profissionais, cada um com sua cor. Clique no olho ao lado de um nome para esconder a coluna dele.',
						print: 'agenda-filtro-01',
						alt: 'Lista de profissionais na lateral da agenda, com o controle de ocultar ao lado de cada nome.'
					},
					{ texto: 'Clique de novo para mostrar. A escolha vale enquanto você estiver navegando.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Escondeu todo mundo? A agenda avisa "Nenhum profissional em exibição" e oferece mostrar todos de volta. Um dia sem coluna visível parece vazio sem estar.'
			}
		],
		vejaTambem: ['visoes-da-agenda', 'cores-e-ocupacao']
	},

	{
		id: 'marcar-um-atendimento',
		secao: 'agenda',
		titulo: 'Marcar um atendimento',
		resumo: 'Do clique no horário vago até o bloco na grade.',
		papeis: BALCAO,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Na visão Dia, clique num espaço vago da coluna do profissional. O formulário abre já com aquele profissional, aquele dia e aquela hora preenchidos.',
						print: 'agenda-marcar-01',
						alt: 'Grade da agenda com o cursor sobre um horário vago.',
						legenda:
							'Prefere o teclado? O botão "Novo agendamento", no alto da agenda, abre o mesmo formulário em branco.'
					},
					{
						texto:
							'Procure o paciente pelo nome. Se ele ainda não estiver cadastrado, cadastre primeiro na área de Pacientes.',
						print: 'agenda-marcar-02',
						alt: 'Formulário Novo agendamento, com a busca de paciente, profissional, tipo, data e hora.'
					},
					{
						texto:
							'Confira o tipo de atendimento: é ele que decide a duração do bloco. Trocar o tipo muda o tamanho do que vai aparecer na grade.'
					},
					{
						texto:
							'Ajuste data e hora se precisar. O relógio sugere de 15 em 15 minutos, mas aceita qualquer horário — um encaixe às 10h07 combinado por telefone pode ser salvo assim mesmo.'
					},
					{
						texto:
							'Use a observação para o recado curto do dia ("vem de muleta", "trazer exame"). Não é prontuário.'
					},
					{
						texto:
							'Clique em "Agendar". O bloco aparece na grade na cor do profissional, e quem mais estiver com esse dia aberto vê o bloco surgir sem recarregar.',
						print: 'agenda-marcar-03',
						alt: 'A grade da agenda com o atendimento recém-criado.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'O profissional não marca atendimento — ele lê a agenda dele. Quem marca é o dono, o administrador ou a recepção.'
			}
		],
		vejaTambem: [
			'horario-ocupado',
			'encaixe',
			'turma-presenca-por-participante',
			'cadastrar-paciente'
		]
	},

	{
		id: 'remarcar-um-atendimento',
		secao: 'agenda',
		titulo: 'Remarcar um atendimento',
		resumo: 'Arrastando na grade, ou pelo painel quando muda o dia.',
		papeis: BALCAO,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Há dois caminhos, e a diferença é o alcance: o arraste move dentro do mesmo dia; o painel move para qualquer dia e troca o profissional.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'No computador, na visão Dia, arraste o bloco para o horário novo — ou para a coluna de outro profissional. A data não muda por arraste.'
					},
					{
						texto:
							'Para mudar o dia, abra o bloco e clique em "Remarcar sessão".',
						print: 'agenda-remarcar-01',
						alt: 'Formulário Remarcar sessão, com data, hora, profissional, motivo e a opção de avisar o paciente.'
					},
					{
						texto:
							'O motivo é opcional e fica registrado — ajuda quem for olhar o histórico depois a entender por que o horário mudou.'
					},
					{
						texto:
							'"Avisar o paciente" já vem marcado: sai uma mensagem com o horário novo. Desmarque quando você já avisou por telefone.'
					},
					{ texto: 'Clique em "Remarcar". A duração do atendimento é preservada.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'No celular não há arraste: use "Remarcar sessão" pelo painel. É de propósito — arrastar com o dedo numa grade de horas erra mais do que acerta.'
			}
		],
		vejaTambem: ['horario-ocupado', 'encaixe', 'o-painel-do-agendamento']
	},

	{
		id: 'horario-ocupado',
		secao: 'agenda',
		titulo: '"Esse horário já está ocupado"',
		resumo: 'Por que o sistema recusa, e quais são as saídas.',
		papeis: BALCAO,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O mesmo profissional não pode estar em dois lugares na mesma hora. Quando você tenta marcar ou remarcar por cima de outro atendimento, o formulário recusa e explica.'
			},
			{
				tipo: 'print',
				print: 'agenda-conflito-01',
				alt: 'Aviso de conflito de horário dentro do formulário, com o botão "Marcar como encaixe".',
				legenda: 'O aviso aparece dentro do próprio formulário — nada do que você digitou se perde.'
			},
			{
				tipo: 'lista',
				itens: [
					'Escolha outro horário ou outro profissional — é a saída normal.',
					'Ou clique em "Marcar como encaixe", quando a sobreposição é intencional.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Fora do expediente é diferente de ocupado. Se o horário está fora do que a clínica ou o profissional atende, nem o encaixe libera — ajuste o horário ou lance uma exceção.'
			}
		],
		vejaTambem: ['encaixe', 'horario-de-funcionamento', 'excecoes']
	},

	{
		id: 'encaixe',
		secao: 'agenda',
		titulo: 'Encaixe: marcar por cima de propósito',
		resumo: 'Quando a sobreposição é a decisão certa, e quem pode tomá-la.',
		papeis: BALCAO,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Encaixe é o atendimento que você marca sabendo que ele sobrepõe outro: o paciente que chegou sem hora, a avaliação rápida entre duas sessões.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'No formulário de marcar ou remarcar, ligue a chave "Encaixe" antes de salvar.',
						print: 'agenda-encaixe-01',
						alt: 'A chave "Encaixe (ignora conflito de horário)" no formulário de agendamento.'
					},
					{
						texto:
							'Se você já tentou salvar e levou a recusa por conflito, a própria caixa de erro oferece "Marcar como encaixe" — é o mesmo efeito, um clique adiante.'
					},
					{
						texto:
							'Na agenda, o bloco encaixado ganha a marca ENCAIXE, para ninguém achar que a sobreposição foi engano.',
						print: 'agenda-encaixe-02',
						alt: 'Painel do agendamento mostrando a marca ENCAIXE ao lado do status.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'Encaixe fura a grade, então é de quem responde pela agenda: dono, administrador e recepção. Para quem não pode, a chave nem aparece.'
			}
		],
		vejaTambem: ['horario-ocupado', 'marcar-um-atendimento']
	},

	{
		id: 'o-painel-do-agendamento',
		secao: 'agenda',
		titulo: 'O painel do agendamento',
		resumo: 'Tudo que dá para fazer depois de clicar num bloco.',
		papeis: TODOS,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Clique em qualquer bloco da agenda e um painel abre à direita. Ele é o centro de operações daquele atendimento.'
			},
			{
				tipo: 'print',
				print: 'agenda-painel-01',
				alt: 'Painel lateral do agendamento aberto, com paciente, profissional, status, horário e as ações.',
				legenda: 'No alto, para quem é a sessão; embaixo, o que dá para fazer com ela.'
			},
			{
				tipo: 'lista',
				itens: [
					'O topo diz o paciente e o profissional — com o pontinho na cor da coluna de onde o bloco veio.',
					'Logo abaixo, o status atual, o horário, o tipo e a observação de quem marcou.',
					'No meio, a lista de quem participa, onde se registra presença e falta.',
					'No pé, "Enviar confirmação" e o botão de excluir; e, no corpo, "Remarcar sessão" e "Cancelar".',
					'No canto superior, o ícone de corrente copia o link deste atendimento.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'Quem só pode ler vê o painel sem o rodapé de ações. Não é erro de carregamento: é o papel.'
			}
		],
		vejaTambem: [
			'registrar-presenca-e-falta',
			'excluir-ou-cancelar',
			'link-do-agendamento',
			'remarcar-um-atendimento'
		]
	},

	{
		id: 'registrar-presenca-e-falta',
		secao: 'agenda',
		titulo: 'Registrar presença e falta',
		resumo: 'O que fazer quando o paciente chega — ou quando não chega.',
		papeis: BALCAO,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Abra o atendimento e olhe a linha do paciente. Enquanto a hora não chega, ela mostra "Previsto" e os botões ficam apagados.',
						print: 'agenda-presenca-01',
						alt: 'Linha do paciente no painel, com os botões Presente e Faltou.'
					},
					{
						texto:
							'A partir do horário da sessão, clique em "Presente" quando o paciente for atendido.'
					},
					{
						texto:
							'Clique em "Faltou" quando ele não vier. O sistema pergunta o motivo — opcional, mas é ele que explica a falta para quem olhar depois.',
						print: 'agenda-falta-01',
						alt: 'Caixa de confirmação da falta, com o campo de motivo.'
					},
					{
						texto:
							'Errou o clique? "Desfazer" volta a linha para "Previsto", sem limite de tempo.'
					}
				]
			},
			{
				tipo: 'texto',
				texto:
					'Depois de registrar uma falta, aparece a chave "Justificada". Ligá-la muda o peso do que aconteceu: falta justificada não conta como falta no total do paciente e não desconta sessão de pacote.'
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Atendimento cancelado não recebe presença. Se a sessão aconteceu, ela não deveria ter sido cancelada — nesse caso, o caminho é reabrir a discussão com quem cancelou, não forçar o registro.'
			}
		],
		vejaTambem: ['turma-presenca-por-participante', 'excluir-ou-cancelar', 'pacotes-o-que-e']
	},

	{
		id: 'turma-presenca-por-participante',
		secao: 'agenda',
		titulo: 'Turma: quando o atendimento é em grupo',
		resumo: 'Vários pacientes no mesmo horário, com presença de cada um.',
		papeis: BALCAO,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Tipos marcados como grupo aceitam mais de um paciente no mesmo bloco — pilates, RPG em turma, hidroterapia. A capacidade vem do tipo de atendimento.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Ao marcar, escolha um tipo de grupo. O campo "Paciente" vira "Participantes", com o contador de quantos cabem.',
						print: 'agenda-turma-01',
						alt: 'Formulário de novo agendamento em grupo, com vários participantes selecionados.'
					},
					{
						texto:
							'No painel, cada participante tem sua própria linha — e sua própria presença.',
						print: 'agenda-turma-02',
						alt: 'Painel de um atendimento em grupo, com uma linha de presença por participante.'
					},
					{
						texto:
							'Registre "Presente" ou "Faltou" pessoa por pessoa. Numa turma de quatro, um pode faltar sem afetar o registro dos outros.'
					}
				]
			},
			{
				tipo: 'texto',
				texto:
					'Enquanto ninguém foi marcado, o bloco mostra o status normal. Depois que a presença começa a ser registrada, ele passa a mostrar a composição — "3 de 4 concluídas" — em vez de uma palavra só, que mentiria sobre os outros.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Cada participante pode estar num pacote diferente — ou em nenhum. O painel mostra o pacote dentro da linha de cada um, e não como uma informação do bloco.'
			}
		],
		vejaTambem: ['registrar-presenca-e-falta', 'tipos-de-atendimento', 'pacotes-o-que-e']
	},

	{
		id: 'excluir-ou-cancelar',
		secao: 'agenda',
		titulo: 'Cancelar ou excluir: qual usar',
		resumo: 'Duas ações parecidas, com consequências bem diferentes.',
		papeis: BALCAO,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'A regra é curta: se o atendimento existiu e não vai acontecer, cancele. Se ele nunca deveria ter sido lançado, exclua.'
			},
			{
				tipo: 'tabela',
				colunas: ['', 'Cancelar', 'Excluir'],
				linhas: [
					['Quando', 'O paciente desmarcou, o profissional faltou', 'Lançamento feito por engano'],
					['O que fica', 'O bloco fica na agenda, marcado como cancelado', 'Some da agenda'],
					['Motivo', 'Pergunta o motivo (opcional) e guarda', 'Não pergunta'],
					['Histórico', 'Entra no histórico do paciente', 'Não entra'],
					['Fila de espera', 'Abre a vaga para quem está na fila', 'Abre a vaga']
				]
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Para cancelar: abra o atendimento, clique em "Cancelar", escreva o motivo se houver, e confirme.',
						print: 'agenda-cancelar-01',
						alt: 'Caixa de confirmação do cancelamento, com o campo de motivo opcional.'
					},
					{
						texto:
							'Para excluir: abra o atendimento e clique no ícone de lixeira, no rodapé do painel. A confirmação avisa que isto é para engano.',
						print: 'agenda-excluir-01',
						alt: 'Caixa de confirmação da exclusão, explicando que ela serve para lançamento feito por engano.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Atendimento que já aconteceu não pode ser excluído — só cancelado ou corrigido. Excluir apagaria a história de um atendimento que existiu de verdade.'
			}
		],
		vejaTambem: ['registrar-presenca-e-falta', 'quem-mexeu-no-que', 'fila-vaga-aberta']
	},

	{
		id: 'link-do-agendamento',
		secao: 'agenda',
		titulo: 'Mandar o link de um atendimento',
		resumo: 'Copiar o endereço direto do bloco para outra pessoa da equipe.',
		papeis: TODOS,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Abra o atendimento e clique no ícone de corrente, no canto superior do painel.',
						print: 'agenda-link-01',
						alt: 'Painel do agendamento com o botão de copiar link destacado no cabeçalho.'
					},
					{
						texto:
							'O endereço vai para a área de transferência. Cole no WhatsApp da equipe, no e-mail, onde precisar.'
					},
					{
						texto:
							'Quem abrir o link cai na agenda com esse atendimento já aberto — desde que tenha acesso à clínica.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'O link é interno, para a equipe. Ele não abre nada para quem não é membro da clínica, e não é o link que o paciente recebe.'
			}
		],
		vejaTambem: ['o-painel-do-agendamento', 'o-que-o-paciente-recebe']
	},

	{
		id: 'cores-e-ocupacao',
		secao: 'agenda',
		titulo: 'As cores e a barra de ocupação',
		resumo: 'Como ler a agenda de longe.',
		papeis: TODOS,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'lista',
				itens: [
					'A cor da faixa lateral de cada bloco é a cor do profissional — a mesma da lista lateral.',
					'O status aparece por palavra no bloco e no painel: Agendado, Confirmado, Em atendimento, Concluído, Faltou, Cancelado.',
					'O cancelado fica riscado e apagado; o concluído, mais discreto — o que já resolveu ocupa menos atenção.',
					'A marca ENCAIXE identifica o bloco que foi marcado por cima de propósito.'
				]
			},
			{
				tipo: 'texto',
				texto:
					'Nas visões Semana e Mês, cada dia tem uma barrinha de ocupação. Ela compara o que está marcado com o que cabe naquele dia: cinza é dia fechado ou vazio, verde é normal, vermelho é acima da capacidade. A barra não é grampeada em 100% de propósito — dia sobrecarregado precisa parecer sobrecarregado.'
			},
			{
				tipo: 'print',
				print: 'agenda-legenda-01',
				alt: 'Legenda da agenda mostrando as cores dos profissionais e os status.'
			}
		],
		vejaTambem: ['visoes-da-agenda', 'tipos-de-atendimento']
	},

	{
		id: 'duas-pessoas-na-mesma-agenda',
		secao: 'agenda',
		titulo: 'Duas pessoas na mesma agenda',
		resumo: 'O que atualiza sozinho, e como saber quem mais está olhando.',
		papeis: TODOS,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'A agenda é compartilhada e se atualiza sozinha. Se a recepção marcar um horário enquanto você está com o mesmo dia aberto, o bloco aparece na sua tela sem você recarregar nada.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'No alto da agenda, ao lado da data, aparecem as iniciais de quem mais está com aquele dia aberto.',
						print: 'agenda-presenca-tempo-real-01',
						alt: 'Indicador no alto da agenda mostrando quem mais está com o dia aberto.'
					},
					{
						texto:
							'Se duas pessoas tentarem mexer no mesmo atendimento ao mesmo tempo, quem chegar depois recebe um aviso em vez de sobrescrever o trabalho da outra.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Perdeu a conexão? A agenda volta a se atualizar sozinha quando a internet retorna. Se ficar em dúvida, recarregar a página nunca faz mal.'
			}
		],
		vejaTambem: ['o-painel-do-agendamento', 'o-sino']
	}
];
