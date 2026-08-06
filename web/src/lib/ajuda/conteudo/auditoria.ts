import type { Topico } from '../tipos';

const GESTAO = ['owner', 'admin'] as const;

export const AUDITORIA: readonly Topico[] = [
	{
		id: 'quem-mexeu-no-que',
		secao: 'auditoria',
		titulo: 'Quem mexeu no quê',
		resumo: 'A trilha do que aconteceu na clínica, com autor e horário.',
		papeis: GESTAO,
		roteiro82: '§2',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'A Auditoria responde a pergunta que aparece quando algo está diferente do combinado: quem fez isso, e quando. Ela registra sozinha — ninguém escreve nela à mão, nem o dono.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Abra Auditoria na barra escura da esquerda.',
						print: 'auditoria-01',
						alt: 'Tela de auditoria, com a lista de eventos e os filtros na lateral.'
					},
					{
						texto:
							'Use os filtros da lateral: período (hoje, 7 dias, 30 dias ou tudo), autor e assunto — agenda, pacientes e profissionais, equipe e acessos, configurações, pacotes e fila, anexos, e acesso negado.'
					},
					{
						texto:
							'Clique num evento para abrir o detalhe: o que mudou, de que valor para que valor.',
						print: 'auditoria-detalhe-01',
						alt: 'Detalhe de um evento da auditoria, mostrando o antes e o depois de cada campo.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'A Auditoria é de dono e administrador. Ela não aparece para recepção nem para profissional.'
			}
		],
		vejaTambem: ['auditoria-limites', 'gerenciar-acessos']
	},

	{
		id: 'auditoria-limites',
		secao: 'auditoria',
		titulo: 'Valores escondidos e prazo da trilha',
		resumo: 'Por que alguns campos não mostram o conteúdo, e por quanto tempo tudo fica.',
		papeis: GESTAO,
		roteiro82: '§2',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Alguns campos aparecem marcados como alterados, mas sem mostrar os valores: CPF, RG, dados bancários e afins. A trilha registra que mudou e quem mudou — sem virar um segundo lugar onde esses dados ficam guardados.'
			},
			{
				tipo: 'texto',
				texto:
					'A trilha também tem prazo: eventos antigos são removidos automaticamente depois do período de retenção. Se você precisa guardar um caso específico por mais tempo, exporte ou registre à parte enquanto ele está visível.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'O filtro "Acesso negado" mostra as tentativas que o sistema recusou. É o primeiro lugar a olhar quando alguém diz que "o sistema não deixou" e você quer saber exatamente o quê.'
			}
		],
		vejaTambem: ['quem-mexeu-no-que', 'quem-ve-os-dados']
	}
];
