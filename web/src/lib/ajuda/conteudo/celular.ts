import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;

export const CELULAR: readonly Topico[] = [
	{
		id: 'no-celular',
		secao: 'celular',
		titulo: 'Usando no celular',
		resumo: 'O que muda na tela pequena — e o que é de propósito.',
		papeis: TODOS,
		roteiro82: '§14',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O sistema inteiro funciona no celular; nenhuma tela fica de fora. O que muda é o arranjo.'
			},
			{
				tipo: 'lista',
				itens: [
					'A barra escura e a coluna de filtros viram uma gaveta, aberta pelo botão de menu no canto superior esquerdo.',
					'Na agenda, a visão Lista é a mais confortável: um atendimento por linha, sem grade para apertar com o dedo.',
					'Os formulários e o painel do atendimento ocupam a tela inteira, em vez de abrir ao lado.'
				]
			},
			{
				tipo: 'print',
				print: 'celular-agenda-01',
				alt: 'A agenda no celular, na visão Lista, com o botão de menu no topo.'
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Não existe arrastar bloco no celular. Para mudar o horário, abra o atendimento e use "Remarcar sessão" — arrastar com o dedo numa grade de horas erra mais do que acerta.'
			}
		],
		vejaTambem: ['instalar-como-aplicativo', 'remarcar-um-atendimento', 'visoes-da-agenda']
	},

	{
		id: 'instalar-como-aplicativo',
		secao: 'celular',
		titulo: 'Instalar como aplicativo',
		resumo: 'Um ícone na tela inicial, sem loja de aplicativos.',
		papeis: TODOS,
		roteiro82: '§14',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O Cinetra pode ficar como um ícone na tela do celular e abrir em tela cheia, sem a barra do navegador. Não há nada para baixar de loja nenhuma.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'No Android, abra o sistema no Chrome, toque no menu de três pontos e escolha "Instalar aplicativo" ou "Adicionar à tela inicial".'
					},
					{
						texto:
							'No iPhone, abra no Safari, toque no botão de compartilhar e escolha "Adicionar à Tela de Início".'
					},
					{
						texto:
							'O ícone aparece junto dos seus aplicativos e abre direto na agenda, já com a sessão de sempre.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Vale para o computador também: navegadores de desktop oferecem a mesma instalação, e o sistema ganha uma janela própria, sem abas do lado.'
			}
		],
		vejaTambem: ['no-celular', 'entrar-sem-senha']
	}
];
