// Política de Privacidade e Termos de Uso das páginas públicas.
//
// **Dado, não markup** — a mesma escolha do `FAQ` em `seo.ts`, pela mesma razão: a página desenha
// o SUMÁRIO e o CORPO do mesmo array, então o índice não tem como listar uma seção que o texto não
// tem (nem o contrário). Um documento legal escrito à mão em `.svelte` é onde essa divergência
// nasce, porque ninguém relê 3 mil palavras para conferir a âncora.
//
// ⚠️ **Nada aqui passou por revisão jurídica** e os dados do controlador ainda são placeholders
// (decisão de 2026-07-29: entram antes de publicar). O texto descreve o que o sistema REALMENTE
// faz, conferido contra o código: isolamento por clínica no banco, trilha de auditoria com
// retenção de 90 dias (`Api.Audit.retencao_dias/0`), anexos em URL assinada com a abertura
// registrada, login sem senha, e os operadores que estão de fato ligados no `runtime.exs`
// (Resend para e-mail, Zernio para WhatsApp, Cloudflare R2 para arquivos). Mexer no produto sem
// mexer aqui faz o documento mentir, que é a única falha grave que esta superfície pode ter.

/** Um parágrafo, ou uma lista de itens. É tudo que o corpo dos documentos precisa. */
export type Bloco = string | { readonly lista: readonly string[] };

export type Secao = {
	readonly id: string;
	readonly titulo: string;
	readonly blocos: readonly Bloco[];
};

export type Documento = {
	readonly id: string;
	readonly caminho: string;
	/** O caminho do OUTRO documento: quem lê um precisa achar o par sem voltar ao rodapé. */
	readonly par: string;
	readonly titulo: string;
	readonly subtitulo: string;
	/** `<meta name="description">` da rota: ≤160 caracteres, o corte do buscador. */
	readonly descricao: string;
	readonly atualizacao: string;
	readonly secoes: readonly Secao[];
};

/**
 * Identificação do controlador.
 *
 * Os campos entre colchetes são PENDÊNCIA declarada, não esquecimento: `legal.test.ts` exige que
 * continuem no formato `[…]` justamente para que ninguém "feche" o texto inventando um CNPJ.
 * Preencher antes de publicar (ver `docs/50-debitos-tecnicos.md`).
 */
export const EMPRESA = {
	nome: 'Cinetra',
	razaoSocial: '[RAZÃO SOCIAL]',
	cnpj: '[CNPJ]',
	endereco: '[ENDEREÇO COMPLETO]',
	encarregado: '[NOME DO ENCARREGADO]',
	// Do domínio de envio, e isso é regra: já foram `@cinetra.app`, domínio nunca registrado
	// (NXDOMAIN), o que fazia o canal do art. 9º da LGPD apontar para o vazio. Ver o teste
	// "os contatos são de um domínio que existe" e o par em `Api.Accounts.Emails`.
	emailPrivacidade: 'privacidade@cinetra.com.br',
	emailContato: 'contato@cinetra.com.br',
	foro: '[COMARCA/UF]'
} as const;

/** Vale para os dois documentos: versões diferentes por página confundem quem compara. */
export const ATUALIZACAO = '29 de julho de 2026';
export const VERSAO = '1.0';

const PRIVACIDADE_SECOES: readonly Secao[] = [
	{
		id: 'quem-somos',
		titulo: 'Quem trata os seus dados',
		blocos: [
			`A Cinetra é um software de gestão para clínicas de fisioterapia, oferecido pela ${EMPRESA.razaoSocial}, inscrita no CNPJ ${EMPRESA.cnpj}, com sede em ${EMPRESA.endereco}. Nesta política, "Cinetra", "nós" e "nosso" se referem a essa empresa.`,
			'Esta política explica quais dados pessoais são tratados quando você usa a plataforma, para que eles servem, com quem são compartilhados, por quanto tempo ficam guardados e como você exerce os seus direitos. Ela se aplica ao site, ao cadastro e ao sistema usado pela clínica.',
			`Dúvidas, pedidos e reclamações sobre dados pessoais podem ser enviados a qualquer momento para ${EMPRESA.emailPrivacidade}.`
		]
	},
	{
		id: 'papeis',
		titulo: 'Dois papéis diferentes, e por que isso importa para você',
		blocos: [
			'A Lei Geral de Proteção de Dados (Lei 13.709/2018) separa quem decide o que fazer com o dado (o controlador) de quem apenas trata o dado a mando de outro (o operador). Na Cinetra, os dois papéis existem ao mesmo tempo, e o seu direito muda conforme o caso.',
			{
				lista: [
					'Dados de quem usa o sistema (a pessoa que cria a conta e a equipe da clínica): a Cinetra é a CONTROLADORA. Somos nós que decidimos guardar o seu nome, o seu e-mail e os registros de acesso para manter a conta funcionando.',
					'Dados dos pacientes cadastrados pela clínica: a clínica é a CONTROLADORA e a Cinetra é a OPERADORA. Quem decide cadastrar um paciente, o que registrar e por quanto tempo manter é a clínica; nós tratamos esses dados seguindo as instruções dela e o contrato de prestação do serviço.'
				]
			},
			'Na prática: se você é paciente e quer acessar, corrigir ou apagar os seus dados, o pedido deve ser feito à clínica que o atende, porque é ela quem responde por essa base. Se a clínica precisar da nossa ajuda técnica para atender ao pedido, nós ajudamos.'
		]
	},
	{
		id: 'dados',
		titulo: 'Que dados são tratados',
		blocos: [
			'Dados de quem usa o sistema, informados no cadastro ou vindos do login com Google: nome, endereço de e-mail e o papel que a pessoa tem dentro da clínica (dona, administração, profissional ou recepção).',
			'Dados da clínica: nome, CNPJ, endereço, fuso horário, horários de funcionamento, tipos de atendimento e o cadastro dos profissionais, incluindo registro no conselho de classe quando informado.',
			'Dados de pacientes, inseridos pela clínica: nome, CPF, data de nascimento, telefone, e-mail, endereço, marcações e observações administrativas, histórico de agendamentos e presenças, pacotes de sessões, além de arquivos que a clínica anexe à ficha, como laudos, pedidos e exames.',
			'Registros de comunicação: as mensagens de lembrete e confirmação enviadas ao paciente por WhatsApp e por e-mail, o resultado do envio e a resposta recebida, além dos pedidos de descadastramento.',
			'Registros técnicos e de segurança: data e hora de acesso, endereço IP, identificação do navegador, sessões abertas e a trilha de auditoria, que guarda quem criou, alterou ou excluiu um cadastro, quando isso aconteceu e o que mudou. A abertura de um anexo da ficha também é registrada.',
			'Não pedimos dados de cartão nem armazenamos dados de pagamento na plataforma. O teste de 14 dias não exige cartão de crédito.'
		]
	},
	{
		id: 'finalidades',
		titulo: 'Para que os dados são usados, e com qual base legal',
		blocos: [
			{
				lista: [
					'Criar e manter a sua conta, autenticar o acesso sem senha e manter a sessão ativa. Base legal: execução do contrato.',
					'Prestar o serviço contratado pela clínica, o que inclui agenda, pacotes de sessões, ficha do paciente, fila de espera e relatórios. Base legal: execução do contrato, e, quanto aos dados de pacientes, as instruções da clínica controladora.',
					'Enviar lembrete e confirmação de sessão ao paciente pelos canais que a clínica ativar. Base legal: a definida pela clínica no contato com o paciente, normalmente o consentimento para receber mensagens, que pode ser revogado sem prejuízo do atendimento.',
					'Manter a trilha de auditoria, prevenir fraude e uso indevido, e responder a incidentes de segurança. Base legal: legítimo interesse e cumprimento de obrigação legal.',
					'Cumprir obrigações legais e regulatórias e exercer direitos em processo administrativo ou judicial. Base legal: obrigação legal e exercício regular de direitos.',
					'Falar com você sobre o serviço, avisos de manutenção, mudanças de política e suporte. Base legal: execução do contrato e legítimo interesse.'
				]
			},
			'Não vendemos dados pessoais, não os cedemos para publicidade de terceiros e não usamos o conteúdo das fichas de pacientes para treinar modelos de inteligência artificial.'
		]
	},
	{
		id: 'saude',
		titulo: 'Dado de saúde e sigilo profissional',
		blocos: [
			'Informação ligada a atendimento de saúde é dado pessoal sensível e recebe proteção reforçada na LGPD. O tratamento desses dados na plataforma se apoia na tutela da saúde, prevista no artigo 11 da lei, e é feito sob a responsabilidade da clínica e dos profissionais que a compõem.',
			'O acesso é limitado pelo papel de cada pessoa dentro da clínica: cada profissional enxerga a própria agenda, e o cadastro e a configuração da clínica ficam com a direção e a administração. A equipe da Cinetra não acessa dados de pacientes na rotina; o acesso só acontece a pedido da clínica, para suporte técnico, e fica registrado.'
		]
	},
	{
		id: 'compartilhamento',
		titulo: 'Com quem os dados são compartilhados',
		blocos: [
			'Para funcionar, a plataforma se apoia em fornecedores que tratam dados por nossa conta, como operadores, limitados ao necessário e obrigados contratualmente a proteger a informação:',
			{
				lista: [
					'Infraestrutura de hospedagem e banco de dados, que mantém a aplicação no ar.',
					'Cloudflare R2, onde ficam os arquivos anexados às fichas.',
					'Resend, que entrega os e-mails do sistema, incluindo o link de acesso e os avisos ao paciente.',
					'Zernio, que entrega as mensagens de WhatsApp aos pacientes.',
					'Ferramentas de monitoramento e registro de erros, que recebem dados técnicos de funcionamento.'
				]
			},
			'Além desses casos, os dados podem ser compartilhados com autoridades públicas quando houver dever legal, ordem judicial ou requisição regular, e com assessores jurídicos e contábeis quando necessário ao exercício de direitos.',
			'Em caso de reorganização societária, fusão ou aquisição, os dados podem ser transferidos ao sucessor, mantidas as condições desta política, e você será avisado antes que a mudança produza efeito.'
		]
	},
	{
		id: 'onde',
		titulo: 'Onde os dados ficam',
		blocos: [
			'A aplicação e o banco de dados são hospedados no Brasil, na região de São Paulo. Cada clínica fica isolada no banco: uma clínica não alcança o dado da outra, e esse isolamento é aplicado pelo próprio banco, não apenas pela tela.',
			'Alguns operadores listados acima operam em outros países, o que caracteriza transferência internacional de dados. Nesses casos a transferência acontece com as salvaguardas previstas na LGPD, por meio de cláusulas contratuais de proteção firmadas com o fornecedor, e limitada ao dado necessário para o serviço que ele presta.'
		]
	},
	{
		id: 'seguranca',
		titulo: 'Como os dados são protegidos',
		blocos: [
			{
				lista: [
					'Todo o tráfego entre o seu navegador e a plataforma é criptografado, com HTTPS obrigatório.',
					'O acesso é sem senha: o login usa link de uso único enviado por e-mail ou a conta Google, o que elimina a senha reutilizada como porta de entrada.',
					'A sessão pode ser encerrada em todos os dispositivos a qualquer momento, pela tela de perfil.',
					'O isolamento entre clínicas é aplicado no banco de dados, por linha, e não depende de o programa lembrar de filtrar.',
					'Os arquivos anexados não ficam em endereço público: cada abertura gera um link assinado e de curta duração, e o acesso fica registrado na trilha.',
					'A trilha de auditoria registra quem criou, alterou ou excluiu cadastro, e dados sensíveis aparecem nela de forma reduzida.'
				]
			},
			`Nenhuma medida elimina o risco por completo. Se acontecer um incidente de segurança capaz de gerar risco relevante aos titulares, comunicaremos a clínica afetada e a Autoridade Nacional de Proteção de Dados, conforme a lei. Se você identificar uma falha, escreva para ${EMPRESA.emailPrivacidade}.`
		]
	},
	{
		id: 'retencao',
		titulo: 'Por quanto tempo os dados ficam guardados',
		blocos: [
			{
				lista: [
					'Dados da conta e da clínica: enquanto a assinatura estiver ativa, e por até 30 dias após o encerramento, para permitir a exportação.',
					'Dados de pacientes: enquanto a clínica mantiver o cadastro, porque é ela quem decide. Encerrada a conta, seguem a regra do item acima.',
					'Trilha de auditoria: 90 dias, prazo aplicado automaticamente por rotina de expurgo.',
					'Registros de comunicação com o paciente e notificações internas: até 90 dias após a leitura, e no máximo 365 dias.',
					'Registros de acesso: pelo prazo do Marco Civil da Internet e por prazos de segurança equivalentes.'
				]
			},
			'Passados esses prazos, os dados são eliminados ou anonimizados, salvo quando a guarda for exigida por obrigação legal ou regulatória, ou for necessária ao exercício de direitos em processo. Registros ligados a atendimento de saúde podem ter prazo próprio de guarda, definido pela regulamentação aplicável à clínica.',
			'Cópias de segurança seguem um ciclo próprio de sobrescrita e podem reter o dado por algumas semanas depois da exclusão na tela.'
		]
	},
	{
		id: 'direitos',
		titulo: 'Os seus direitos',
		blocos: [
			'A LGPD garante a você, a qualquer momento e sem custo:',
			{
				lista: [
					'confirmar se tratamos dados seus e acessar esses dados;',
					'corrigir dado incompleto, inexato ou desatualizado;',
					'pedir anonimização, bloqueio ou eliminação de dado desnecessário, excessivo ou tratado fora da lei;',
					'pedir a portabilidade para outro fornecedor;',
					'saber com quem compartilhamos os seus dados;',
					'revogar o consentimento, quando for essa a base do tratamento;',
					'opor-se a tratamento feito com base em legítimo interesse;',
					'peticionar contra o controlador perante a Autoridade Nacional de Proteção de Dados.'
				]
			},
			`Para exercer qualquer um deles, escreva para ${EMPRESA.emailPrivacidade}. Podemos pedir informação adicional para confirmar a sua identidade, o que protege você contra pedido feito por terceiro. Respondemos no prazo da lei.`,
			'Se você é paciente de uma clínica que usa a Cinetra, direcione o pedido à clínica: ela é a controladora dessa base. Se preferir escrever para nós, encaminhamos o pedido a ela e prestamos o apoio técnico necessário.'
		]
	},
	{
		id: 'cookies',
		titulo: 'Cookies',
		blocos: [
			'A Cinetra usa apenas cookies necessários ao funcionamento. O principal é o cookie de sessão, que mantém você autenticado depois do login: ele é criptografado, marcado como inacessível a scripts do navegador e enviado apenas por conexão segura.',
			'Não usamos cookie de publicidade, de perfilamento ou de rede social, e não há rastreador de terceiros nas páginas do sistema. Apagar os cookies do navegador encerra a sessão e obriga a entrar de novo, sem outro efeito sobre os seus dados.'
		]
	},
	{
		id: 'criancas',
		titulo: 'Crianças e adolescentes',
		blocos: [
			'A conta da plataforma é para uso profissional e não se destina a menores de 18 anos. Pacientes menores de idade podem ser cadastrados pela clínica, no melhor interesse da criança ou do adolescente, cabendo à clínica obter o consentimento específico do pai, da mãe ou do responsável legal quando a lei exigir.'
		]
	},
	{
		id: 'alteracoes',
		titulo: 'Mudanças nesta política',
		blocos: [
			'Esta política pode mudar quando o serviço mudar ou quando a regulamentação exigir. A data de atualização no topo da página sempre indica a versão em vigor, e mudanças relevantes serão avisadas por e-mail ou dentro do sistema antes de produzirem efeito.'
		]
	},
	{
		id: 'contato',
		titulo: 'Como falar com a gente',
		blocos: [
			`Encarregado pelo tratamento de dados pessoais: ${EMPRESA.encarregado}.`,
			`Para pedidos e dúvidas sobre privacidade: ${EMPRESA.emailPrivacidade}. Para os demais assuntos: ${EMPRESA.emailContato}.`,
			`Endereço para correspondência: ${EMPRESA.endereco}.`
		]
	}
];

const TERMOS_SECOES: readonly Secao[] = [
	{
		id: 'aceite',
		titulo: 'Aceite destes termos',
		blocos: [
			`Estes Termos de Uso regulam o acesso e o uso da Cinetra, plataforma de gestão para clínicas de fisioterapia oferecida pela ${EMPRESA.razaoSocial}, CNPJ ${EMPRESA.cnpj}. Ao criar uma conta, entrar no sistema ou usar qualquer funcionalidade, você declara que leu, entendeu e concorda com estes termos e com a Política de Privacidade.`,
			'Se você cria a conta em nome de uma clínica, declara ter poderes para assumir estas obrigações por ela. Se não concordar com algum ponto, não use a plataforma.'
		]
	},
	{
		id: 'servico',
		titulo: 'O que a Cinetra é, e o que não é',
		blocos: [
			'A Cinetra é um software de organização administrativa: agenda com detecção de conflito, cadastro de pacientes, pacotes de sessões, fila de espera, lembrete e confirmação de sessão, controle de acesso por papel e relatórios de ocupação. O uso é feito pelo navegador, sem instalação.',
			'A Cinetra não presta serviço de saúde, não realiza diagnóstico, não indica tratamento e não interfere na conduta clínica. Toda decisão assistencial é do profissional habilitado, e a plataforma não substitui o julgamento dele nem as obrigações do conselho de classe.',
			'A plataforma também não é sistema de prontuário eletrônico certificado, não emite documento com valor fiscal e não executa cobrança de paciente. Registro clínico com exigência legal específica deve ser mantido pela clínica no meio adequado.'
		]
	},
	{
		id: 'conta',
		titulo: 'Conta, acesso e responsabilidade da equipe',
		blocos: [
			'O acesso é individual e sem senha: você entra por um link de uso único enviado ao seu e-mail ou pela sua conta Google. Manter esse e-mail seguro é responsabilidade sua, porque quem tem acesso à caixa de entrada tem acesso à conta.',
			'Cada pessoa da equipe deve ter o próprio acesso. Compartilhar login com colega quebra a trilha de auditoria, que é o registro de quem fez o quê, e passa a ser risco para a clínica em qualquer apuração.',
			'A clínica é responsável por manter a lista de acessos em dia, o que inclui remover quem saiu da equipe, e por escolher corretamente o papel de cada pessoa, já que é o papel que define o que ela pode ver e fazer.',
			'Avise imediatamente se suspeitar de acesso indevido. A sessão pode ser encerrada em todos os dispositivos pela própria tela de perfil.'
		]
	},
	{
		id: 'planos',
		titulo: 'Teste grátis, planos e pagamento',
		blocos: [
			'O teste é de 14 dias e não exige cartão de crédito. Durante o teste, o serviço é oferecido no estado em que se encontra, e você pode parar de usar quando quiser, sem cobrança.',
			'Terminado o teste, o uso continuado depende da contratação de um plano. Os valores, os limites de cada plano e a periodicidade de cobrança são os informados na página de planos no momento da contratação. A assinatura se renova automaticamente ao fim de cada período, salvo cancelamento antes da renovação.',
			'O cancelamento pode ser feito a qualquer momento, sem multa e sem fidelidade. O acesso segue até o fim do período já pago, e não há devolução proporcional do período em curso, salvo quando a lei determinar.',
			'Reajustes de preço serão comunicados com pelo menos 30 dias de antecedência e só valem a partir do período seguinte. Atraso no pagamento pode levar à suspensão do acesso, com aviso prévio.'
		]
	},
	{
		id: 'dados-do-cliente',
		titulo: 'Os dados da clínica são da clínica',
		blocos: [
			'Todo dado inserido na plataforma pela clínica e pela sua equipe continua pertencendo à clínica. A Cinetra recebe apenas a autorização necessária para hospedar, processar, exibir e transmitir esse dado enquanto presta o serviço, além de gerar estatísticas agregadas e anonimizadas, que não identificam pessoa nem clínica.',
			'Em relação aos dados dos pacientes, a clínica é a controladora e a Cinetra é a operadora, como detalha a Política de Privacidade. Cabe à clínica ter base legal para tratar esses dados, informar o paciente e atender aos pedidos que ele fizer.',
			'A clínica se compromete a inserir apenas dado que tenha o direito de tratar, e a não usar a plataforma como repositório de informação estranha à finalidade de gestão do atendimento.'
		]
	},
	{
		id: 'comunicacao',
		titulo: 'Mensagens enviadas ao paciente',
		blocos: [
			'A plataforma envia lembrete, confirmação e aviso de sessão ao paciente por WhatsApp e por e-mail, conforme a clínica configurar. O disparo é feito a partir do cadastro que a clínica mantém, e o conteúdo e o momento das mensagens são definidos por ela.',
			'A clínica é responsável por ter autorização do paciente para contatá-lo por esses canais, por manter o contato correto e por respeitar o pedido de descadastramento, que a plataforma registra e passa a observar automaticamente.',
			'É proibido usar a plataforma para envio de propaganda em massa, promoção de terceiros ou qualquer mensagem estranha ao atendimento. Além de violar estes termos, isso descumpre as regras dos provedores de mensagem e pode levar ao bloqueio do canal.',
			'A entrega da mensagem depende de terceiros, como a operadora e a plataforma de mensagens, e do aparelho do destinatário. A Cinetra não garante entrega nem leitura, e o lembrete não substitui a confirmação feita pela recepção quando ela for indispensável.'
		]
	},
	{
		id: 'uso-aceitavel',
		titulo: 'Uso aceitável',
		blocos: [
			'Ao usar a plataforma, você concorda em não:',
			{
				lista: [
					'usá-la para fim ilícito, enganoso ou que viole direito de terceiro;',
					'tentar acessar dado de outra clínica, conta ou paciente sem autorização;',
					'burlar limites de plano, controle de acesso ou mecanismo de segurança;',
					'fazer engenharia reversa, copiar, revender, sublicenciar ou oferecer a plataforma como serviço próprio;',
					'automatizar acesso de forma que degrade o desempenho do serviço para os demais;',
					'enviar código malicioso ou conteúdo que viole a lei ou direito autoral.'
				]
			},
			'O descumprimento pode levar à suspensão imediata do acesso, sem prejuízo das medidas cabíveis.'
		]
	},
	{
		id: 'disponibilidade',
		titulo: 'Disponibilidade, manutenção e suporte',
		blocos: [
			'Trabalhamos para manter a plataforma disponível de forma contínua, mas o serviço pode ficar indisponível por manutenção programada, falha de fornecedor, incidente de segurança ou evento fora do nosso controle. Manutenções previsíveis serão avisadas com antecedência sempre que possível.',
			'O suporte é prestado em português, por e-mail, em dias úteis. Enquanto não houver acordo de nível de serviço assinado, não há prazo de resposta contratado nem garantia de disponibilidade em percentual.',
			'A plataforma evolui: recursos podem ser acrescentados, alterados ou descontinuados. Mudança que reduza de forma relevante uma funcionalidade essencial do seu plano será avisada com antecedência.'
		]
	},
	{
		id: 'propriedade',
		titulo: 'Propriedade intelectual',
		blocos: [
			'O software, a marca Cinetra, a identidade visual, os textos e a documentação são de titularidade da empresa e protegidos por lei. Estes termos concedem apenas uma licença de uso, limitada, não exclusiva, intransferível e revogável, restrita ao período da assinatura e à finalidade prevista aqui.',
			'Sugestões e ideias de melhoria que você nos enviar podem ser usadas livremente no produto, sem que isso gere obrigação de pagamento ou de reconhecimento.'
		]
	},
	{
		id: 'responsabilidade',
		titulo: 'Limitação de responsabilidade',
		blocos: [
			'A Cinetra responde por danos diretos comprovadamente causados por falha do serviço, limitados ao valor pago pela clínica nos 12 meses anteriores ao evento. Não respondemos por lucro cessante, perda de oportunidade, dano indireto, nem por prejuízo decorrente de dado incorreto inserido pela clínica, de decisão clínica tomada pelo profissional ou de indisponibilidade causada por terceiro.',
			'Estes limites não se aplicam a dolo, culpa grave, dano causado a consumidor quando a lei vedar a limitação, nem a obrigação que a lei declare indisponível.',
			'A clínica deve manter os registros exigidos pela regulamentação que a alcança por meios próprios sempre que a lei assim determinar. A plataforma é ferramenta de apoio, não arquivo legal da clínica.'
		]
	},
	{
		id: 'encerramento',
		titulo: 'Suspensão, encerramento e saída dos dados',
		blocos: [
			'Você pode encerrar a conta quando quiser. Podemos suspender ou encerrar o acesso em caso de descumprimento destes termos, uso que ameace a segurança da plataforma ou inadimplência não resolvida após aviso.',
			'Encerrada a conta, os dados ficam disponíveis para exportação por 30 dias. Passado esse prazo, são eliminados ou anonimizados conforme a Política de Privacidade, ressalvado o que a lei obrigue a guardar.'
		]
	},
	{
		id: 'alteracoes',
		titulo: 'Mudanças nestes termos',
		blocos: [
			'Estes termos podem ser atualizados. A data no topo da página indica a versão em vigor, e alterações relevantes serão comunicadas por e-mail ou dentro do sistema com pelo menos 30 dias de antecedência. Continuar usando a plataforma depois desse prazo significa concordar com a nova versão; se não concordar, você pode encerrar a conta sem custo.'
		]
	},
	{
		id: 'lei',
		titulo: 'Lei aplicável, foro e contato',
		blocos: [
			`Estes termos são regidos pela lei brasileira. Fica eleito o foro da comarca de ${EMPRESA.foro} para dirimir controvérsias, ressalvado o direito do consumidor de acionar o foro do seu domicílio.`,
			'Antes de qualquer medida judicial, procure a gente: a maior parte dos problemas se resolve por e-mail, e responder é do nosso interesse.',
			`Contato: ${EMPRESA.emailContato}. Assuntos de privacidade e proteção de dados: ${EMPRESA.emailPrivacidade}.`
		]
	}
];

export const PRIVACIDADE: Documento = {
	id: 'privacidade',
	caminho: '/privacidade',
	par: '/termos',
	titulo: 'Política de Privacidade',
	subtitulo:
		'Que dados a Cinetra trata, para quê, por quanto tempo e como você exerce os seus direitos.',
	descricao:
		'Como a Cinetra trata dados de clínicas e pacientes: finalidades, base legal, compartilhamento, prazo de guarda e direitos do titular pela LGPD.',
	atualizacao: ATUALIZACAO,
	secoes: PRIVACIDADE_SECOES
};

export const TERMOS: Documento = {
	id: 'termos',
	caminho: '/termos',
	par: '/privacidade',
	titulo: 'Termos de Uso',
	subtitulo: 'As regras do serviço, o que cabe à Cinetra e o que cabe à sua clínica.',
	descricao:
		'Condições de uso da Cinetra: conta e acessos, planos e cancelamento, dados da clínica, mensagens ao paciente, responsabilidades e encerramento.',
	atualizacao: ATUALIZACAO,
	secoes: TERMOS_SECOES
};

/** Os dois, na ordem em que aparecem no rodapé e no sitemap. */
export const DOCUMENTOS: readonly Documento[] = [PRIVACIDADE, TERMOS];

/** Acha o documento de uma rota (`/termos`), ou `undefined`. */
export function documentoPorCaminho(caminho: string): Documento | undefined {
	return DOCUMENTOS.find((d) => d.caminho === caminho);
}

/**
 * Todo o texto visível de um documento, num string só.
 *
 * Existe para os testes de copy (sem HTML, sem travessão, contato presente) poderem varrer o
 * documento inteiro sem recursão duplicada em cada asserção.
 */
export function textoDe(doc: Documento): string {
	const blocos = doc.secoes.flatMap((secao) => [
		secao.titulo,
		...secao.blocos.flatMap((bloco) => (typeof bloco === 'string' ? [bloco] : bloco.lista))
	]);

	return [doc.titulo, doc.subtitulo, ...blocos].join('\n');
}
