import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;
const BALCAO = ['owner', 'admin', 'recepcao'] as const;

export const PROBLEMAS: readonly Topico[] = [
	{
		id: 'nao-recebi-o-link',
		secao: 'problemas',
		titulo: 'Não recebi o e-mail com o link',
		resumo: 'Três causas, na ordem em que costumam acontecer.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'lista',
				itens: [
					'Olhe a caixa de spam ou promoções. É a causa mais comum, de longe.',
					'Confira se o e-mail digitado é o mesmo do cadastro — um endereço parecido não recebe nada, e a tela não avisa que errou (ela é sempre igual, para não revelar quem tem conta).',
					'Você se cadastrou e nunca abriu o primeiro link? Então a conta ainda não existe, e pedir link na tela de entrada não envia nada. Refaça o cadastro em "Criar conta".'
				]
			},
			{
				tipo: 'texto',
				texto:
					'Se foi um convite da clínica que não chegou, quem administra pode reenviá-lo em Configurações → Equipe & acessos.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Vale conferir com a equipe de TI se o domínio do remetente está bloqueado — clínicas com e-mail corporativo às vezes barram remetente novo.'
			}
		],
		vejaTambem: ['criar-sua-conta', 'entrar-sem-senha', 'gerenciar-acessos']
	},

	{
		id: 'link-nao-vale-mais',
		secao: 'problemas',
		titulo: '"Esse link expirou ou já foi usado"',
		resumo: 'O link de entrada vale uma vez e tem prazo.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Cada link de acesso serve para uma entrada só, e expira depois de um tempo. Ver esta mensagem quase sempre significa uma destas duas coisas.'
			},
			{
				tipo: 'lista',
				itens: [
					'Você já entrou com esse link antes e clicou nele de novo — inclusive sem querer, ao reabrir o e-mail.',
					'O e-mail ficou parado tempo demais antes de você abrir.'
				]
			},
			{
				tipo: 'texto',
				texto:
					'A saída é a mesma nos dois casos: peça outro na tela de entrada. Se você pediu dois links seguidos, os dois valem — o que foi usado é que deixa de valer.'
			}
		],
		vejaTambem: ['entrar-sem-senha', 'nao-recebi-o-link']
	},

	{
		id: 'muitas-tentativas',
		secao: 'problemas',
		titulo: '"Muitas tentativas, tente daqui a pouco"',
		resumo: 'O limite de pedidos, e por que ele existe.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Pedir vários links de acesso em sequência faz o sistema segurar por alguns minutos. É uma proteção: sem ela, qualquer pessoa poderia disparar e-mails em nome da sua conta.'
			},
			{
				tipo: 'lista',
				itens: [
					'Espere alguns minutos e tente de novo — o bloqueio se solta sozinho.',
					'Enquanto espera, procure na caixa de spam: é provável que os links anteriores tenham chegado.',
					'Se o Google estiver disponível para sua conta, "Continuar com Google" não passa por esse limite.'
				]
			}
		],
		vejaTambem: ['entrar-sem-senha', 'nao-recebi-o-link']
	},

	{
		id: 'fui-deslogado',
		secao: 'problemas',
		titulo: 'Fui deslogado no meio do trabalho',
		resumo: 'O que aconteceu e como não perder o que estava digitando.',
		papeis: TODOS,
		roteiro82: '§1',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'A sessão tem validade e cai sozinha depois de um tempo. Ela também cai na hora se alguém — você mesmo, de outro aparelho — usar "Sair de todos os dispositivos".'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Antes de recarregar, copie o que você digitou e ainda não salvou. Ao voltar do login, o formulário abre em branco.'
					},
					{ texto: 'Entre de novo do jeito de sempre. Você volta para a mesma clínica.' },
					{
						texto:
							'Confira se o que você estava fazendo chegou a ser salvo — sobretudo se o clique em salvar foi o que levou você para o login.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Acontecendo com frequência num computador só, desconfie de bloqueio de cookies ou de uma extensão que limpa dados do navegador.'
			}
		],
		vejaTambem: ['sair-de-todos-os-dispositivos', 'entrar-sem-senha', 'nao-vejo-um-menu']
	},

	{
		id: 'horario-nao-aparece',
		secao: 'problemas',
		titulo: 'A agenda não mostra o horário que eu esperava',
		resumo: 'Quatro configurações decidem o que a grade desenha.',
		papeis: BALCAO,
		roteiro82: '§6',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Quando um horário não aparece — ou aparece e recusa marcação —, a causa está em uma destas quatro, nesta ordem.'
			},
			{
				tipo: 'lista',
				itens: [
					'O horário de funcionamento da clínica: se o dia não tem faixa, ele é dia fechado.',
					'Uma exceção lançada para aquela data: feriado, recesso, horário especial.',
					'O horário do profissional, quando ele não segue o da clínica.',
					'Uma exceção de data do próprio profissional: férias, congresso.'
				]
			},
			{
				tipo: 'texto',
				texto:
					'Também vale conferir o óbvio: a coluna daquele profissional pode estar escondida pelo filtro da lateral da agenda.'
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Precisa marcar mesmo assim, uma vez só? Encaixe resolve sobreposição, mas não libera horário fora do expediente. Fora do expediente, o caminho é ajustar o horário ou lançar uma exceção.'
			}
		],
		vejaTambem: ['horario-de-funcionamento', 'excecoes', 'horario-do-profissional', 'encaixe']
	},

	{
		id: 'paciente-nao-recebeu',
		secao: 'problemas',
		titulo: 'O paciente diz que não recebeu a mensagem',
		resumo: 'Onde conferir se ela saiu, e o que costuma barrar.',
		papeis: BALCAO,
		roteiro82: '§9',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Abra o atendimento e veja a seção "Comunicação": ela mostra se algo saiu e em que estado ficou.'
					},
					{
						texto:
							'Nada listado? Então nenhuma mensagem foi enviada — lembre-se de que a confirmação parte do botão "Enviar confirmação", não sozinha.'
					},
					{
						texto:
							'Aparece como falhou? Confira o contato na ficha: número errado, e-mail com erro de digitação.'
					},
					{
						texto:
							'Aparece como enviada mas ele não viu? Confirme o consentimento na ficha e se ele não se descadastrou pelo link da mensagem.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Se o botão "Enviar confirmação" está desabilitado, ninguém daquele atendimento pode receber agora. Passe o mouse por cima: o motivo aparece ali.'
			}
		],
		vejaTambem: ['ver-o-que-foi-enviado', 'descadastro-do-paciente', 'canal-e-silencio']
	},

	{
		id: 'erro-ao-enviar-anexo',
		secao: 'problemas',
		titulo: 'Erro ao enviar um anexo',
		resumo: 'Tamanho, formato e conexão — nessa ordem.',
		papeis: BALCAO,
		roteiro82: '§4',
		blocos: [
			{
				tipo: 'lista',
				itens: [
					'Arquivo muito grande é a causa mais comum. Foto de documento tirada pelo celular costuma passar do limite — reduza a resolução ou gere um PDF.',
					'Conexão instável durante o envio interrompe o upload. Tente de novo com sinal melhor.',
					'Se o erro repetir com o mesmo arquivo e outros funcionarem, o problema é o arquivo: reexporte ou tire outra foto.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Vale digitalizar documento como PDF em vez de foto: fica menor, mais legível e imprime melhor.'
			}
		],
		vejaTambem: ['anexos-do-paciente', 'falar-com-o-suporte']
	},

	{
		id: 'falar-com-o-suporte',
		secao: 'problemas',
		titulo: 'Como falar com o suporte',
		resumo: 'O que mandar junto para a resposta vir na primeira volta.',
		papeis: TODOS,
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Antes de escrever, procure o assunto aqui na ajuda — boa parte das dúvidas está descrita com o passo a passo. Se não resolver, mande a mensagem com estas informações.'
			},
			{
				tipo: 'lista',
				itens: [
					'O que você estava tentando fazer, em uma frase.',
					'O que aconteceu, com o texto exato da mensagem de erro, se houver.',
					'O nome da clínica e o e-mail com que você entra.',
					'O dia e a hora aproximados — é o que permite reconstituir o caso na trilha de auditoria.',
					'Uma captura de tela, quando o problema é visual.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Nunca mande dados de paciente por canal aberto além do necessário. Nome e horário do atendimento bastam para localizar o caso — CPF, endereço e documentos não são precisos.'
			}
		],
		vejaTambem: ['quem-ve-os-dados', 'termos-e-privacidade']
	}
];
