import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;

export const PRIMEIROS_PASSOS: readonly Topico[] = [
	{
		id: 'o-que-e-o-cinetra',
		secao: 'primeiros-passos',
		titulo: 'O que é o Cinetra e como ele se organiza',
		resumo: 'Clínica, equipe, pacientes e agenda: como as peças se encaixam.',
		papeis: TODOS,
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O Cinetra é o sistema onde a sua clínica marca atendimentos, guarda a ficha dos pacientes e acompanha o que aconteceu em cada sessão. Tudo gira em torno de quatro peças.'
			},
			{
				tipo: 'lista',
				itens: [
					'A clínica é o espaço fechado onde tudo mora. Pacientes, agenda, profissionais e histórico pertencem a uma clínica, e ninguém de fora dela enxerga nada.',
					'A equipe são as pessoas que entram no sistema. Cada uma tem um papel, e o papel decide o que ela vê e o que ela pode mexer.',
					'Os profissionais são quem atende. Cada um tem uma cor, uma coluna na agenda e um horário próprio de trabalho.',
					'Os pacientes têm ficha, histórico de atendimentos e — quando você quiser — pacotes de sessões.'
				]
			},
			{
				tipo: 'texto',
				texto:
					'A agenda é onde essas quatro peças se encontram: um atendimento é um paciente, com um profissional, de um tipo, numa hora. Se alguma dessas peças ainda não existe, a agenda não deixa marcar — e é por isso que a ordem de configuração importa no primeiro dia.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Se você acabou de assumir uma clínica nova no sistema, comece pelo roteiro do primeiro dia: ele põe as peças na ordem certa.'
			}
		],
		vejaTambem: ['roteiro-do-primeiro-dia', 'conhecendo-a-tela']
	},

	{
		id: 'criar-sua-conta',
		secao: 'primeiros-passos',
		titulo: 'Criar sua conta',
		resumo: 'O cadastro leva dois campos e não pede senha.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O Cinetra não usa senha. Você se cadastra com nome e e-mail, e a entrada acontece por um link enviado para esse e-mail — ou pela sua conta Google.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Abra a página de cadastro e preencha seu nome e seu e-mail.',
						print: 'conta-criar-01',
						alt: 'Tela "Criar sua conta" com os campos Nome e E-mail e o botão "Criar conta grátis".'
					},
					{
						texto:
							'Clique em "Criar conta grátis". Se preferir, use "Continuar com Google" — nesse caso você entra direto, sem passar pelo e-mail.'
					},
					{
						texto:
							'A tela avisa que a mensagem foi enviada. Abra seu e-mail e clique no link para entrar pela primeira vez.',
						print: 'conta-criar-02',
						alt: 'Tela "Verifique seu e-mail", confirmando o envio do link de acesso.',
						legenda:
							'Esta tela é sempre igual, tenha o e-mail dado certo ou não — é assim de propósito, para não revelar quem tem conta no sistema.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Sua conta só passa a existir de verdade quando você abre o link. Se você se cadastrou e nunca abriu, pedir um link na tela de entrada não vai enviar nada — repita o cadastro.'
			}
		],
		vejaTambem: ['entrar-sem-senha', 'nao-recebi-o-link', 'criar-a-clinica']
	},

	{
		id: 'entrar-sem-senha',
		secao: 'primeiros-passos',
		titulo: 'Entrar: o link por e-mail e o Google',
		resumo: 'Dois caminhos de entrada, nenhum deles com senha para lembrar.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Abra a página de entrada e digite o e-mail com que você foi cadastrado.',
						print: 'conta-entrar-01',
						alt: 'Tela "Bem-vindo de volta" com o campo de e-mail e o botão "Enviar link de acesso".'
					},
					{
						texto:
							'Clique em "Enviar link de acesso" e abra a mensagem que chegou. O link entra direto, sem pedir mais nada.'
					},
					{
						texto:
							'Se sua conta usa Google, o caminho mais curto é "Continuar com Google" — nenhum e-mail no meio.'
					}
				]
			},
			{
				tipo: 'texto',
				texto:
					'Cada link vale uma vez só. Se você pedir dois e clicar no primeiro, ele funciona; se clicar de novo no mesmo link depois de já ter entrado, a tela recusa e oferece pedir outro.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'O link expira. Se demorar para abrir o e-mail, peça outro — leva o mesmo tempo que tentar adivinhar se ainda vale.'
			}
		],
		vejaTambem: ['nao-recebi-o-link', 'link-nao-vale-mais', 'criar-sua-conta']
	},

	{
		id: 'criar-a-clinica',
		secao: 'primeiros-passos',
		titulo: 'Criar a clínica',
		resumo: 'O primeiro acesso pede um nome, e você vira o dono.',
		papeis: ['owner'],
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Se você entrou e ainda não pertence a nenhuma clínica, o sistema leva você direto para esta tela. Quem cria a clínica é o dono dela.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Dê um nome à clínica — o que os seus pacientes reconhecem.',
						print: 'conta-clinica-01',
						alt: 'Tela "Vamos criar sua clínica" com o campo Nome da clínica.'
					},
					{
						texto:
							'Clique em "Criar clínica". Você entra nela na hora, já como dono, e a agenda abre vazia.'
					}
				]
			},
			{
				tipo: 'texto',
				texto:
					'A clínica nasce com cinco tipos de atendimento prontos (avaliação, sessão e afins), para você conseguir marcar o primeiro horário sem configurar nada antes. Ajuste-os quando sobrar tempo.'
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'Foi você quem criou? Então você é o dono, e é o único papel que não pode ser removido da clínica — sempre existe pelo menos um.'
			}
		],
		vejaTambem: ['roteiro-do-primeiro-dia', 'tipos-de-atendimento', 'trocar-de-clinica']
	},

	{
		id: 'conhecendo-a-tela',
		secao: 'primeiros-passos',
		titulo: 'Conhecendo a tela',
		resumo: 'A barra escura da esquerda, a coluna de filtros e o topo.',
		papeis: TODOS,
		blocos: [
			{
				tipo: 'print',
				print: 'shell-01',
				alt: 'Tela da agenda com a barra escura à esquerda, a coluna de filtros ao lado e a barra do topo.',
				legenda: 'A mesma estrutura vale para todas as telas do sistema.'
			},
			{
				tipo: 'lista',
				itens: [
					'A barra escura da esquerda leva às áreas do sistema: Agenda, Pacientes, Profissionais, Fila de espera, Relatórios, Auditoria e Configurações.',
					'No pé dessa barra ficam o sino das notificações e o botão que troca entre tema claro e escuro.',
					'A coluna ao lado muda conforme a área: na agenda ela filtra profissionais, em Configurações ela lista as telas de ajuste.',
					'No topo fica o nome da área aberta e, à direita, seu avatar — é por ele que se troca de clínica, abre o perfil e sai.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'Você não vê todos os ícones que a dona vê. Auditoria só aparece para dono e administrador, e o profissional não tem acesso à área de Profissionais. Isso é o papel funcionando, não um defeito.'
			}
		],
		vejaTambem: ['os-quatro-papeis', 'nao-vejo-um-menu', 'no-celular']
	},

	{
		id: 'trocar-de-clinica',
		secao: 'primeiros-passos',
		titulo: 'Trocar de clínica',
		resumo: 'Quem atende em mais de uma clínica troca pelo avatar, sem sair.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Clique no seu avatar, no canto superior direito.',
						print: 'shell-menu-01',
						alt: 'Menu do usuário aberto, com o perfil, a lista de clínicas e a saída.'
					},
					{
						texto:
							'Em "Clínicas", clique na que você quer abrir. A atual aparece marcada e não é clicável.'
					},
					{
						texto:
							'A tela recarrega já dentro da outra clínica. Agenda, pacientes e tudo o mais trocam junto.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Seu papel pode ser diferente em cada clínica: dona em uma, recepção em outra. O que você vê muda junto com a troca.'
			}
		],
		vejaTambem: ['seu-perfil-e-o-tema', 'os-quatro-papeis']
	},

	{
		id: 'seu-perfil-e-o-tema',
		secao: 'primeiros-passos',
		titulo: 'Seu perfil, o tema e a saída',
		resumo: 'Trocar seu nome, alternar claro/escuro e sair da sessão.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Clique no avatar e depois em "Meu perfil".',
						print: 'perfil-01',
						alt: 'Tela Meu perfil, com o nome editável, o e-mail bloqueado e a lista de clínicas.'
					},
					{
						texto:
							'O nome pode ser trocado e passa a valer em todo o sistema. O e-mail não muda: é ele que identifica sua conta na entrada.'
					},
					{
						texto:
							'O tema claro ou escuro é o último botão da barra escura, no canto inferior esquerdo. A escolha fica guardada no seu navegador.',
						print: 'perfil-tema-01',
						alt: 'A mesma tela da agenda no tema escuro.'
					},
					{ texto: 'Para sair, clique no avatar e em "Sair".' }
				]
			}
		],
		vejaTambem: ['sair-de-todos-os-dispositivos', 'trocar-de-clinica']
	},

	{
		id: 'sair-de-todos-os-dispositivos',
		secao: 'primeiros-passos',
		titulo: 'Sair de todos os dispositivos',
		resumo: 'O que fazer quando você esqueceu a sessão aberta em outro lugar.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Ficou logada no computador da recepção, no celular antigo, no notebook que foi para o conserto? Em vez de caçar cada aparelho, derrube tudo de uma vez.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Abra "Meu perfil" pelo avatar e desça até a área "Sessão".',
						print: 'perfil-sessao-01',
						alt: 'Área "Sessão" da tela de perfil, com o botão de sair de todos os dispositivos.'
					},
					{
						texto:
							'Clique em "Sair de todos os dispositivos" e confirme. Isso encerra a sessão em todo lugar, inclusive aqui.'
					},
					{ texto: 'Entre de novo, do jeito de sempre: link por e-mail ou Google.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Use isto sempre que suspeitar que alguém acessou sua conta, e sempre que perder um aparelho com a clínica aberta nele.'
			}
		],
		vejaTambem: ['fui-deslogado', 'seu-perfil-e-o-tema']
	},

	{
		id: 'roteiro-do-primeiro-dia',
		secao: 'primeiros-passos',
		titulo: 'Roteiro do primeiro dia',
		resumo: 'A ordem que faz a clínica funcionar em uma sentada.',
		papeis: ['owner', 'admin'],
		blocos: [
			{
				tipo: 'texto',
				texto:
					'A ordem abaixo não é gosto: cada passo depende do anterior. Marcar um atendimento exige um profissional, um paciente e um tipo; e o horário só aparece na grade se o expediente estiver configurado.'
			},
			{
				tipo: 'lista',
				itens: [
					'1. Confira os dados da clínica — nome, contato e CNPJ.',
					'2. Ajuste os tipos de atendimento: duração e cor de cada um. Cinco já vêm prontos.',
					'3. Defina o horário de funcionamento da clínica: dias e faixas em que se atende.',
					'4. Cadastre os profissionais e, se o horário de algum for diferente do da clínica, ajuste o dele.',
					'5. Convide a equipe e escolha o papel de cada pessoa.',
					'6. Lance as exceções que você já conhece: feriados, recesso, férias marcadas.',
					'7. Cadastre o primeiro paciente.',
					'8. Marque o primeiro atendimento e confira se ele caiu onde você esperava.',
					'9. Antes de ligar os avisos automáticos, dê uma olhada em Comunicação para saber o que o paciente vai receber.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Não precisa cadastrar todos os pacientes de uma vez. A ficha pode nascer no momento de marcar o primeiro horário de cada um.'
			}
		],
		vejaTambem: [
			'tipos-de-atendimento',
			'horario-de-funcionamento',
			'cadastrar-profissional',
			'convidar-alguem',
			'cadastrar-paciente',
			'marcar-um-atendimento'
		]
	}
];
