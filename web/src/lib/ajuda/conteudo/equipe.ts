import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;
const GESTAO = ['owner', 'admin'] as const;

export const EQUIPE: readonly Topico[] = [
	{
		id: 'convidar-alguem',
		secao: 'equipe',
		titulo: 'Convidar alguém para a equipe',
		resumo: 'Dar acesso ao sistema para mais uma pessoa da clínica.',
		papeis: GESTAO,
		roteiro82: '§2',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Vá em Configurações → Equipe & acessos.',
						print: 'equipe-lista-01',
						alt: 'Tela de equipe e acessos, com a lista de membros e seus papéis.'
					},
					{
						texto: 'Clique em "Convidar" e preencha o nome e o e-mail de quem vai entrar.',
						print: 'equipe-convite-01',
						alt: 'Formulário de convite, com nome, e-mail e a escolha do papel.'
					},
					{
						texto:
							'Escolha o papel. A descrição embaixo de cada opção resume o que ele permite — e a tabela "O que cada papel pode", na mesma tela, tem o detalhe.'
					},
					{
						texto:
							'Se a pessoa é um profissional já cadastrado, ligue o convite ao cadastro dela na lista de vínculo. É isso que faz a agenda dela ser reconhecida como dela.'
					},
					{
						texto:
							'Envie. A pessoa recebe um e-mail com o convite; enquanto ela não aceitar, ela aparece na lista como pendente.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'A tela também lista os "Profissionais sem acesso" — quem atende mas nunca foi convidado. É o lugar mais rápido para descobrir quem ainda está de fora.'
			}
		],
		vejaTambem: ['os-quatro-papeis', 'aceitar-um-convite', 'gerenciar-acessos']
	},

	{
		id: 'os-quatro-papeis',
		secao: 'equipe',
		titulo: 'Os quatro papéis',
		resumo: 'Dono, administrador, profissional e recepção: o que muda entre eles.',
		papeis: TODOS,
		roteiro82: '§2',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Todo mundo que entra na clínica tem exatamente um papel, e é ele que decide o que a pessoa vê e o que ela pode mexer.'
			},
			{
				tipo: 'tabela',
				colunas: ['Papel', 'Para quem', 'Em uma frase'],
				linhas: [
					['Dono', 'Quem criou a clínica', 'Controle total, inclusive da própria clínica.'],
					[
						'Administrador',
						'Sócio, coordenador, gerente',
						'Acesso total: configurações, equipe, todas as agendas e relatórios.'
					],
					[
						'Profissional',
						'Quem atende',
						'Vê a própria agenda e as fichas dos pacientes, sem mexer na agenda.'
					],
					[
						'Recepção',
						'O balcão',
						'Opera a agenda e o cadastro de pacientes, sem as configurações sensíveis.'
					]
				]
			},
			{
				tipo: 'texto',
				texto:
					'O detalhe área por área fica dentro do sistema, em Configurações → Equipe & acessos, na tabela "O que cada papel pode". Ela é gerada a partir das mesmas regras que o sistema aplica de verdade — por isso ela, e não esta página, é a palavra final.'
			},
			{
				tipo: 'print',
				print: 'equipe-matriz-01',
				alt: 'Tabela "O que cada papel pode", com uma linha por área do sistema e uma coluna por papel.',
				legenda: 'A tabela vive dentro do sistema justamente para nunca divergir das regras.'
			},
			{
				tipo: 'lista',
				itens: [
					'Sempre existe pelo menos um dono — o último não pode ser removido nem rebaixado.',
					'O papel é por clínica: a mesma pessoa pode ser dona em uma e recepção em outra.',
					'Quem tem papel mais fraco não "perde" dado: ele simplesmente não aparece.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Na dúvida entre Administrador e Recepção: quem precisa mexer em horário, tipos, equipe ou ver relatórios é Administrador. Quem opera a agenda e o cadastro é Recepção.'
			}
		],
		vejaTambem: ['nao-vejo-um-menu', 'convidar-alguem', 'o-que-o-profissional-ve']
	},

	{
		id: 'aceitar-um-convite',
		secao: 'equipe',
		titulo: 'Aceitar um convite',
		resumo: 'Você foi convidado: o que fazer com o e-mail que chegou.',
		papeis: TODOS,
		roteiro82: '§2',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Abra o e-mail do convite e clique no link. Ele leva direto para dentro da clínica.'
					},
					{
						texto:
							'Se você ainda não tinha conta, ela é criada nesse momento — sem senha, como todo o resto.'
					},
					{
						texto:
							'Se você já usa o Cinetra em outra clínica, a nova aparece no menu do avatar, e você troca entre elas quando quiser.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'O convite é do e-mail para onde ele foi enviado. Aceitar de outra conta não funciona — se o endereço estiver errado, peça um novo convite.'
			}
		],
		vejaTambem: ['trocar-de-clinica', 'nao-recebi-o-link', 'entrar-sem-senha']
	},

	{
		id: 'gerenciar-acessos',
		secao: 'equipe',
		titulo: 'Reenviar, trocar papel e remover acesso',
		resumo: 'A manutenção da equipe depois do convite enviado.',
		papeis: GESTAO,
		roteiro82: '§2',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Em Configurações → Equipe & acessos, cada linha tem as ações à direita.',
						print: 'equipe-acoes-01',
						alt: 'Linha de um membro da equipe com os botões de reenviar convite, editar e remover acesso.'
					},
					{
						texto:
							'Convite pendente pode ser reenviado — útil quando o e-mail se perdeu na caixa de spam.'
					},
					{
						texto:
							'O lápis edita o membro: é por ali que se troca o papel de alguém e se ajusta o vínculo com o cadastro de profissional.'
					},
					{
						texto:
							'"Remover acesso" tira a pessoa da clínica. Ela deixa de entrar; o que ela fez continua registrado.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Remover acesso não apaga os atendimentos que a pessoa marcou nem o histórico dela na trilha de auditoria. É assim de propósito: a história da clínica não muda quando alguém sai.'
			}
		],
		vejaTambem: ['os-quatro-papeis', 'quem-mexeu-no-que', 'convidar-alguem']
	},

	{
		id: 'nao-vejo-um-menu',
		secao: 'equipe',
		titulo: '"Não vejo um menu que outra pessoa vê"',
		resumo: 'Quase sempre é o papel — e dá para conferir em dez segundos.',
		papeis: TODOS,
		roteiro82: '§12',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'O sistema esconde o que o seu papel não alcança, em vez de mostrar e recusar depois. Então "sumiu o menu" quase sempre quer dizer "este papel não tem essa área".'
			},
			{
				tipo: 'lista',
				itens: [
					'Auditoria: só dono e administrador.',
					'Profissionais: não aparece para quem entra como Profissional.',
					'Configurações: dono e administrador editam; os outros só leem o que é público da clínica.',
					'Ações do painel do agendamento: quem não opera a agenda vê o painel sem o rodapé de ações.'
				]
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Confira seu papel: clique no avatar; ele aparece junto do nome da clínica ativa.'
					},
					{
						texto:
							'Está em mais de uma clínica? Confirme em qual você está — o papel muda de uma para outra.'
					},
					{
						texto:
							'Se o papel estiver errado mesmo, quem corrige é o dono ou um administrador, em Equipe & acessos.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Se o menu sumiu de uma hora para outra sem ninguém mexer no seu papel, recarregue a página: pode ser uma sessão que expirou no meio do caminho.'
			}
		],
		vejaTambem: ['os-quatro-papeis', 'fui-deslogado', 'trocar-de-clinica']
	}
];
