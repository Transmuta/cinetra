import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;
const BALCAO = ['owner', 'admin', 'recepcao'] as const;
const GESTAO = ['owner', 'admin'] as const;

export const COMUNICACAO: readonly Topico[] = [
	{
		id: 'o-que-o-paciente-recebe',
		secao: 'comunicacao',
		titulo: 'O que o paciente recebe, e quando',
		resumo: 'Nada sai sozinho por relógio: as mensagens partem de uma ação da equipe.',
		papeis: TODOS,
		roteiro82: '§9',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O Cinetra não dispara mensagem no horário. Toda comunicação com o paciente nasce de algo que alguém fez no sistema — e isso é de propósito: mensagem automática que ninguém acompanha vira reclamação que ninguém explica.'
			},
			{
				tipo: 'tabela',
				colunas: ['O que dispara', 'O que o paciente recebe'],
				linhas: [
					[
						'"Enviar confirmação", no painel do atendimento',
						'A confirmação do horário marcado, com o contato da clínica'
					],
					[
						'Remarcar com "Avisar o paciente" ligado',
						'O aviso com o horário novo'
					],
					['O link de descadastro, em qualquer mensagem', 'A saída para não receber mais']
				]
			},
			{
				tipo: 'lista',
				itens: [
					'Só recebe quem tem contato na ficha e autorizou receber.',
					'O canal depende da configuração da clínica: WhatsApp ligado ou apenas e-mail.',
					'Mensagem que cairia na janela de silêncio é adiada, não descartada.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Como nada sai sozinho, vale combinar com a equipe em que momento a confirmação é enviada — no fim do dia anterior, por exemplo.'
			}
		],
		vejaTambem: ['canal-e-silencio', 'ver-o-que-foi-enviado', 'paciente-nao-recebeu']
	},

	{
		id: 'canal-e-silencio',
		secao: 'comunicacao',
		titulo: 'Escolher o canal e a janela de silêncio',
		resumo: 'WhatsApp ou e-mail, e o horário em que a clínica não incomoda.',
		papeis: GESTAO,
		roteiro82: '§9',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Vá em Configurações → Comunicação.',
						print: 'comunicacao-01',
						alt: 'Tela de comunicação, com a chave de WhatsApp e a janela de silêncio.'
					},
					{
						texto:
							'"Falar por WhatsApp" vale para todas as mensagens ao paciente. Desligado, tudo continua saindo por e-mail.'
					},
					{
						texto:
							'"Não incomodar" define o intervalo em que a clínica não manda nada. O que cairia nesse intervalo sai no fim da janela.'
					},
					{ texto: 'Salve.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Para ligar o WhatsApp é preciso ter o telefone da clínica cadastrado em Dados da clínica. Ele vai dentro da mensagem — quem responde ao WhatsApp automático não é lido por ninguém, e o paciente precisa de um número para ligar.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto: 'Cada mensagem de WhatsApp é cobrada; e-mail, não. Vale considerar isso na decisão.'
			}
		],
		vejaTambem: ['dados-da-clinica', 'o-que-o-paciente-recebe']
	},

	{
		id: 'ver-o-que-foi-enviado',
		secao: 'comunicacao',
		titulo: 'Conferir o que foi enviado',
		resumo: 'O histórico de mensagens de cada atendimento.',
		papeis: TODOS,
		roteiro82: '§9',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Abra o atendimento na agenda e desça até "Comunicação", dentro do painel.',
						print: 'comunicacao-timeline-01',
						alt: 'Histórico de comunicação dentro do painel do agendamento, com as mensagens e seus estados.'
					},
					{
						texto:
							'Cada linha mostra o que saiu, por qual canal e em que estado: na fila, entregue, lido ou falhou.'
					},
					{
						texto:
							'"Nada a mostrar" quer dizer exatamente isso: nenhuma mensagem foi enviada para este atendimento ainda.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Antes de reenviar, olhe aqui. É comum a mensagem já ter saído e o paciente não ter visto — e duas mensagens iguais confundem mais do que ajudam.'
			}
		],
		vejaTambem: ['paciente-nao-recebeu', 'o-que-o-paciente-recebe']
	},

	{
		id: 'descadastro-do-paciente',
		secao: 'comunicacao',
		titulo: 'O paciente pediu para não receber mais',
		resumo: 'Como funciona o descadastro, e o que ele afeta.',
		papeis: BALCAO,
		roteiro82: '§9',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Toda mensagem leva um link de saída. Quando o paciente clica nele, ele mesmo se descadastra, sem passar pela clínica.'
			},
			{
				tipo: 'lista',
				itens: [
					'Ele para de receber os avisos automáticos daquele canal.',
					'A ficha dele passa a mostrar isso nos selos do topo.',
					'O atendimento continua igual: descadastro é sobre mensagem, não sobre tratamento.'
				]
			},
			{
				tipo: 'texto',
				texto:
					'Se o pedido veio pelo balcão ("não quero mais receber WhatsApp"), o caminho é a ficha: edite os consentimentos do paciente.'
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Não force o reenvio para quem saiu da lista. Além de ser o pedido explícito da pessoa, o botão "Enviar confirmação" fica desabilitado quando ninguém do atendimento pode receber — e o motivo aparece ao passar o mouse.'
			}
		],
		vejaTambem: ['ver-o-que-foi-enviado', 'cadastrar-paciente', 'pedidos-do-paciente-lgpd']
	}
];
