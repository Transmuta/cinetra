import type { Topico } from '../tipos';

const TODOS = ['owner', 'admin', 'profissional', 'recepcao'] as const;
const BALCAO = ['owner', 'admin', 'recepcao'] as const;

export const PACIENTES: readonly Topico[] = [
	{
		id: 'cadastrar-paciente',
		secao: 'pacientes',
		titulo: 'Cadastrar um paciente',
		resumo: 'O que é obrigatório, o que pode esperar e o que o sistema preenche sozinho.',
		papeis: BALCAO,
		roteiro82: '§4',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'A ficha é longa porque cobre da recepção ao repasse do convênio — mas quase nada é obrigatório. Para marcar um horário, basta o nome.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Em Pacientes, clique em "Novo paciente".',
						print: 'pacientes-lista-01',
						alt: 'Lista de pacientes com a busca e o botão de novo paciente.'
					},
					{
						texto:
							'Preencha a Identificação: nome, como a pessoa prefere ser chamada, telefone e documento. O telefone e o CPF ganham máscara sozinhos enquanto você digita.',
						print: 'pacientes-novo-01',
						alt: 'Formulário de cadastro de paciente, aberto na seção Identificação.'
					},
					{
						texto:
							'Em "Endereço & e-mail", digite o CEP: logradouro, bairro, cidade e estado vêm preenchidos. Só o número fica com você.'
					},
					{
						texto:
							'As seções seguintes — emergência, dados profissionais, atendimento, convênio e preferências clínicas — podem ser preenchidas depois, na edição.'
					},
					{
						texto:
							'Em "Consentimento", registre o que o paciente autorizou. É isso que decide se ele pode receber confirmação e lembrete.',
						print: 'pacientes-novo-02',
						alt: 'Seção de consentimento do cadastro, com a autorização de contato e a nota da LGPD.'
					},
					{ texto: 'Salve. A ficha abre pronta para uso.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'O contador ao lado de cada seção mostra quantos campos dela você já preencheu. Serve para retomar depois sem reler a ficha inteira.'
			}
		],
		vejaTambem: ['paciente-duplicado', 'a-ficha-do-paciente', 'o-que-o-paciente-recebe']
	},

	{
		id: 'paciente-duplicado',
		secao: 'pacientes',
		titulo: '"Esse paciente já existe"',
		resumo: 'O aviso de ficha repetida e por que vale a pena parar para ler.',
		papeis: BALCAO,
		roteiro82: '§4',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Enquanto você digita nome, telefone, CPF ou e-mail, o sistema procura em silêncio se já existe ficha com aquele dado. Se existir, ele avisa antes de você salvar.'
			},
			{
				tipo: 'print',
				print: 'pacientes-duplicado-01',
				alt: 'Aviso de dado já cadastrado, apontando a ficha existente.',
				legenda: 'O aviso diz qual campo bateu e em qual ficha.'
			},
			{
				tipo: 'lista',
				itens: [
					'Se a ficha encontrada está ativa, edite aquela em vez de criar outra.',
					'Se ela está arquivada, reative — o histórico de atendimentos vem junto.',
					'Se for mesmo outra pessoa (nome comum, telefone da família), siga e salve.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Ficha duplicada é o problema mais caro de desfazer: o histórico fica partido entre as duas, e nenhuma conta a história inteira. Um minuto de conferência aqui poupa uma tarde depois.'
			}
		],
		vejaTambem: ['cadastrar-paciente', 'arquivar-e-reativar']
	},

	{
		id: 'encontrar-um-paciente',
		secao: 'pacientes',
		titulo: 'Encontrar um paciente',
		resumo: 'A busca aceita nome, telefone e documento.',
		papeis: TODOS,
		roteiro82: '§4',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Abra Pacientes e digite na busca. Serve pedaço do nome, telefone ou documento.',
						print: 'pacientes-busca-01',
						alt: 'Busca da lista de pacientes com um termo digitado e os resultados abaixo.'
					},
					{
						texto:
							'A lista mostra telefone, preferência de contato e as tags de cada um. Clique na linha para abrir a ficha.'
					},
					{
						texto:
							'Não achou? O paciente pode estar arquivado — use o filtro da coluna lateral para incluir os arquivados na busca.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'Na hora de marcar um atendimento, você não precisa vir até aqui: o próprio formulário da agenda busca o paciente pelo nome.'
			}
		],
		vejaTambem: ['a-ficha-do-paciente', 'arquivar-e-reativar', 'marcar-um-atendimento']
	},

	{
		id: 'a-ficha-do-paciente',
		secao: 'pacientes',
		titulo: 'A ficha do paciente',
		resumo: 'Onde ficam o histórico, as próximas sessões, os pacotes e os anexos.',
		papeis: TODOS,
		roteiro82: '§4',
		blocos: [
			{
				tipo: 'print',
				print: 'pacientes-ficha-01',
				alt: 'Ficha do paciente com os dados à esquerda e a coluna de atividade à direita.',
				legenda: 'À esquerda quem a pessoa é; à direita o que já aconteceu e o que vem.'
			},
			{
				tipo: 'lista',
				itens: [
					'No topo: o nome, os selos do que o paciente autorizou receber e os botões Agendar, Editar dados e Arquivar.',
					'"Próximas sessões" mostra o que já está marcado daqui para a frente.',
					'"Pacotes" lista os blocos de sessões contratados e quantas ainda faltam.',
					'"Histórico" lista o que já aconteceu, com presença, falta e o motivo de cada uma.',
					'"Anexos e documentos" guarda pedido médico, exame, termo assinado.'
				]
			},
			{
				tipo: 'aviso',
				tom: 'dica',
				texto:
					'O botão "Agendar" leva direto ao formulário da agenda com esse paciente já escolhido. É o caminho mais curto quando ele está na sua frente no balcão.'
			}
		],
		vejaTambem: ['anexos-do-paciente', 'pacotes-o-que-e', 'registrar-presenca-e-falta']
	},

	{
		id: 'anexos-do-paciente',
		secao: 'pacientes',
		titulo: 'Anexar documentos e exames',
		resumo: 'Enviar, abrir, renomear e remover arquivos da ficha.',
		papeis: BALCAO,
		roteiro82: '§4',
		blocos: [
			{
				tipo: 'passos',
				passos: [
					{
						texto:
							'Na ficha, desça até "Anexos e documentos". Arraste o arquivo para a área indicada ou clique nela para escolher.',
						print: 'pacientes-anexos-01',
						alt: 'Área de anexos da ficha, com a caixa de arrastar arquivo e a lista de anexos.'
					},
					{ texto: 'O arquivo aparece na lista assim que o envio termina.' },
					{
						texto:
							'Cada anexo tem três ações: abrir, renomear e remover. Renomear ajuda a diferenciar três "documento.pdf" na mesma ficha.'
					}
				]
			},
			{
				tipo: 'aviso',
				tom: 'atencao',
				texto:
					'Cada abertura de anexo fica registrada na trilha de auditoria — documento de paciente é dado sensível, e quem o abriu é parte da história.'
			}
		],
		vejaTambem: ['a-ficha-do-paciente', 'quem-mexeu-no-que', 'erro-ao-enviar-anexo']
	},

	{
		id: 'arquivar-e-reativar',
		secao: 'pacientes',
		titulo: 'Arquivar e reativar um paciente',
		resumo: 'Tirar da lista quem não está em tratamento, sem perder a história.',
		papeis: ['owner', 'admin'],
		roteiro82: '§4',
		blocos: [
			{
				tipo: 'texto',
				texto:
					'Paciente que terminou o tratamento não precisa sumir: ele é arquivado. A ficha sai da lista de ativos e continua inteira — histórico, anexos e pacotes ficam onde estavam.'
			},
			{
				tipo: 'passos',
				passos: [
					{
						texto: 'Na ficha, clique em "Arquivar" e confirme.',
						print: 'pacientes-arquivar-01',
						alt: 'Ficha do paciente com o botão Arquivar em destaque.'
					},
					{
						texto:
							'A ficha passa a mostrar a faixa "Paciente arquivado" no topo, com o botão "Reativar" ao lado.',
						print: 'pacientes-arquivado-01',
						alt: 'Faixa de paciente arquivado no topo da ficha, com o botão Reativar.'
					},
					{ texto: 'Voltou a tratar? "Reativar" devolve a ficha à lista, do jeito que estava.' }
				]
			},
			{
				tipo: 'aviso',
				tom: 'papel',
				texto:
					'Arquivar é de dono e administrador. A recepção cadastra e edita, mas não tira ficha de circulação.'
			}
		],
		vejaTambem: ['paciente-duplicado', 'encontrar-um-paciente', 'pedidos-do-paciente-lgpd']
	}
];
