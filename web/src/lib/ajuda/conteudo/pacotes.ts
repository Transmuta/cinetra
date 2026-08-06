import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;
const BALCAO = ['owner', 'admin', 'recepcao'] as const;

export const PACOTES: readonly Topico[] = [
	{
		id: 'pacotes-o-que-e',
		secao: 'pacotes',
		titulo: 'O que é um pacote de sessões',
		resumo: 'Dez sessões vendidas de uma vez, marcadas de uma vez, controladas sozinhas.',
		papeis: TODOS,
		roteiro82: '§8',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Pacote é o combinado do tipo "dez sessões, terças e quintas às 9h". Em vez de marcar dez atendimentos na mão, você descreve a regra uma vez e o sistema cria a série inteira.'
			},
			{
				tipo: 'texto',
				texto:
					'Depois de criado, o pacote também conta: quantas sessões foram usadas, quantas faltam e quando está acabando. O cartão avisa quando o pacote está no fim, para a renovação não ser lembrada tarde demais.'
			},
			{
				tipo: 'print',
				print: 'pacotes-cartao-01',
				alt: 'Cartão de pacote na ficha do paciente, com as sessões usadas, as restantes e a próxima sessão.',
				legenda: 'Cada bolinha é uma sessão: as cheias já aconteceram.'
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'Criar pacote é agendar em série, então é do balcão: dono, administrador e recepção. O profissional consulta.'
			}
		],
		vejaTambem: ['pacotes-criar', 'pacotes-gerir']
	},

	{
		id: 'pacotes-criar',
		secao: 'pacotes',
		titulo: 'Criar um pacote',
		resumo: 'A grade semanal, a prévia e o que fazer quando dá conflito.',
		papeis: BALCAO,
		roteiro82: '§8',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Abra a ficha do paciente e, na área de pacotes, clique em "Novo pacote".',
						print: 'pacotes-novo-01',
						alt: 'Formulário de novo pacote, com tipo, profissional, quantidade de sessões e data de início.'
					},
					{
						texto:
							'Escolha o tipo de atendimento e o profissional, e diga quantas sessões o pacote tem.'
					},
					{
						texto:
							'Defina a data de início e marque, na grade semanal, os dias e horários em que a sessão se repete.',
						print: 'pacotes-grade-01',
						alt: 'Grade semanal do pacote, com os dias marcados e os horários escolhidos.'
					},
					{
						texto:
							'Decida o que uma falta faz: "Falta desconta uma sessão" ou "Falta não desconta". É a regra comercial do seu pacote — e ela vale para o pacote inteiro.'
					},
					{
						texto:
							'Confira a "Prévia da série": ela lista as datas que serão criadas antes de qualquer coisa ser gravada. Datas com conflito de horário vêm sinalizadas.',
						print: 'pacotes-previa-01',
						alt: 'Prévia da série, listando as datas que serão criadas e destacando as que têm conflito.'
					},
					{
						texto:
							'Ajuste a grade até a prévia ficar como você quer, e salve. As sessões aparecem na agenda em seguida.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'A prévia é o momento barato de errar. Depois de criado, o pacote continua ajustável, mas cada sessão já existe na agenda — e algumas podem já ter sido confirmadas ao paciente.'
			}
		],
		vejaTambem: ['pacotes-gerir', 'horario-ocupado', 'pacotes-sessoes']
	},

	{
		id: 'pacotes-sessoes',
		secao: 'pacotes',
		titulo: 'Ver as sessões de um pacote',
		resumo: 'A trilha de bolinhas, e o que cada estado quer dizer.',
		papeis: TODOS,
		roteiro82: '§8',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'No cartão do pacote, abra "Sessões". A lista mostra cada sessão na ordem, com data e estado.',
						print: 'pacotes-sessoes-01',
						alt: 'Lista das sessões de um pacote, com data e estado de cada uma.'
					},
					{
						texto:
							'Clique numa sessão para abrir o atendimento dela na agenda — é lá que está o porquê de uma falta ou de um cancelamento.'
					},
					{
						texto:
							'Acabou de criar e a lista está vazia? A série é montada em segundo plano; aguarde alguns instantes e reabra.'
					}
				]
			}
		],
		vejaTambem: ['pacotes-gerir', 'registrar-presenca-e-falta']
	},

	{
		id: 'pacotes-gerir',
		secao: 'pacotes',
		titulo: 'Pausar, ajustar e cancelar um pacote',
		resumo: 'O que fazer quando o combinado muda no meio.',
		papeis: BALCAO,
		roteiro82: '§8',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O cartão do pacote informa; quem executa é o menu de três pontos, no canto dele.'
			},
			{
				tipo: 'print',
				print: 'pacotes-menu-01',
				alt: 'Menu do cartão de pacote, com pausar, ajustar grade e cancelar.'
			},
			{
				tipo: 'lista',
				itens: [
					'Pausar: o paciente viajou, machucou, vai parar por um tempo. Retomar devolve o pacote ao ritmo.',
					'Ajustar grade: mudou o dia ou o horário combinado. Vale para as sessões que ainda não aconteceram.',
					'Cancelar pacote: o combinado acabou antes da hora. O que já aconteceu continua no histórico.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Pacote não se apaga — cancela. O histórico do paciente precisa continuar explicando as sessões que ele fez, e um pacote apagado deixaria sessões órfãs no meio do histórico.'
			},
			{
				tipo: 'texto',
				texto:
					'Quando todas as sessões são consumidas, o cartão avisa que o pacote terminou. Aí você arquiva pelo menu, ou acrescenta sessões se o tratamento continuar.'
			}
		],
		vejaTambem: ['pacotes-criar', 'pacotes-sessoes', 'a-ficha-do-paciente']
	}
];
