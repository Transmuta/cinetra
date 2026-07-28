// Metadados de busca e compartilhamento das páginas públicas (doc 57).
//
// Fica em `$lib` (e não solto no `+page.svelte`) porque três superfícies precisam concordar:
// as tags do `<head>`, o `sitemap.xml` e o `robots.txt`. Divergir aqui não quebra nada visível —
// só faz o Google indexar uma URL que o sitemap não lista, ou compartilhar um link com título
// diferente do da página.

/** Identidade da marca nas superfícies públicas. */
export const SITE = {
	nome: 'Cinetra',
	// O título era "Cinetra · a agenda que cuida da sua clínica": bonito, e sem nenhum termo que
	// alguém digita na busca. Quem procura este produto procura "sistema/software para clínica
	// de fisioterapia" — o padrão `termo · marca` põe isso antes do corte de ~60 caracteres.
	titulo: 'Cinetra · agenda e gestão para clínicas de fisioterapia',
	// A manchete do herói. Vende melhor que o título de busca em card de rede social, onde o
	// leitor já veio por um link e não por uma consulta.
	manchete: 'Sua clínica respira quando a agenda cuida de si mesma.',
	// ~155 caracteres: o que o Google costuma exibir antes de truncar.
	descricao:
		'Software de gestão para clínicas de fisioterapia: agenda sem conflito, pacotes de sessões com controle de renovação e confirmação automática no WhatsApp.',
	locale: 'pt_BR',
	idioma: 'pt-BR'
} as const;

/**
 * A URL canônica desta página.
 *
 * Sai de `event.url`, não de constante: sob `adapter-node` a origem vem do `ORIGIN` do
 * fly.toml, então a mesma função devolve `localhost` em desenvolvimento e o domínio real em
 * produção — sem uma segunda variável para esquecer de trocar.
 *
 * A query string É descartada de propósito: `?utm_source=…` em campanha criaria uma URL
 * canônica por campanha, que é justamente o conteúdo duplicado que a canônica existe para
 * evitar. A barra final some, exceto na raiz.
 */
export function canonical(url: URL): string {
	const caminho = url.pathname.replace(/\/+$/, '');
	return `${url.origin}${caminho || '/'}`;
}

/** Páginas públicas que entram no sitemap. O resto do app exige sessão e não se indexa. */
export const PAGINAS_PUBLICAS = [
	{ caminho: '/', prioridade: '1.0', frequencia: 'weekly' },
	{ caminho: '/criar-conta', prioridade: '0.8', frequencia: 'monthly' },
	{ caminho: '/entrar', prioridade: '0.5', frequencia: 'monthly' }
] as const;

/**
 * Áreas que o robô não deve varrer. Todas exigem sessão e devolvem redirect para `/entrar`,
 * então rastreá-las só gasta o orçamento de rastreamento do site em 302 — e ainda faz o
 * Google registrar URLs internas que nunca vão render resultado.
 */
export const AREAS_PRIVADAS = [
	'/agenda',
	'/pacientes',
	'/profissionais',
	'/fila',
	'/relatorios',
	'/notificacoes',
	'/auditoria',
	'/configuracoes',
	'/perfil',
	'/comecar',
	'/auth/',
	'/api/'
] as const;

/**
 * As perguntas da seção de dúvidas da landing.
 *
 * **Fonte única de propósito.** A mesma lista desenha a seção e alimenta o `FAQPage` do JSON-LD.
 * Dado estruturado que não bate com o texto visível é motivo de ação manual do Google — e a
 * maneira de duas listas divergirem é existirem duas listas.
 *
 * `resposta` é texto puro (sem HTML): é o que o schema.org aceita sem escapar, e o que a tela
 * renderiza como parágrafo.
 *
 * ⚠️ **Três respostas são PROMESSA COMERCIAL, não descrição do que está construído** — decisão
 * do produto em 2026-07-27, registrada no [doc 57]. Antes de publicar, precisam de confirmação:
 *   - `migracao`  → não existe importador nenhum no código; a resposta promete serviço assistido;
 *   - `cancelar`  → não existe cobrança implementada;
 *   - `confirmacao` → o doc 52 põe o WhatsApp na fase 2 (a fase 1 é e-mail via Resend).
 * As outras cinco são verificáveis contra o código e podem ir ao ar como estão.
 */
export const FAQ = [
	{
		id: 'migracao',
		pergunta: 'Consigo trazer os dados que já tenho hoje?',
		resposta:
			'Sim. Você envia a planilha ou a exportação do sistema atual e nós importamos os pacientes e o histórico antes de você começar a usar, sem ninguém redigitar cadastro. Se hoje tudo vive num caderno, a equipe ajuda a montar a primeira agenda junto com você.'
	},
	{
		id: 'instalacao',
		pergunta: 'Preciso instalar alguma coisa?',
		resposta:
			'Não. A Cinetra roda no navegador, no computador da recepção e no celular de quem atende. Não há programa para instalar, servidor para manter nem backup para lembrar de fazer.'
	},
	{
		id: 'confirmacao',
		pergunta: 'Como funciona a confirmação de sessão?',
		resposta:
			'A Cinetra manda o lembrete pelo WhatsApp e por e-mail antes da sessão, e o paciente confirma ou pede para remarcar com um toque. Quando alguém desmarca, o horário volta na hora para a fila de espera e é oferecido a quem está esperando, em vez de virar buraco na agenda.'
	},
	{
		id: 'lgpd',
		pergunta: 'E a LGPD? Onde ficam os dados dos meus pacientes?',
		// Dizia "toda LEITURA e alteração entra numa trilha". A leitura não entra: o AshPaperTrail
		// versiona escrita. O que é auditado na leitura é a abertura de anexo (`:visualizou`,
		// doc 51). Corrigido para descrever o que existe.
		resposta:
			'Os dados ficam em servidores no Brasil, na região de São Paulo. Cada clínica fica isolada no banco de dados, toda alteração de cadastro entra numa trilha de auditoria que mostra quem mudou o quê e quando, e a abertura de um laudo ou exame também fica registrada. O tratamento do dado de saúde se apoia na tutela da saúde, como manda a LGPD para quem presta assistência; o contato para lembrete é consentimento separado, que o paciente pode revogar a qualquer momento sem afetar o atendimento.'
	},
	{
		id: 'permissoes',
		pergunta: 'Quem da minha equipe enxerga o quê?',
		// A primeira versão dizia que a recepção "agenda sem precisar abrir dado clínico". É falso:
		// `Patient` não tem field policy nenhuma e a policy de leitura autoriza QUALQUER papel da
		// clínica, então a recepção abre a ficha inteira — como precisa, para atender no balcão.
		// Quem tem recorte é o profissional (`OwnAgendaOnly`, A7/D1: só a própria agenda).
		resposta:
			'Cada pessoa entra com o próprio acesso e o papel define o que ela pode fazer: dona, administração, profissional e recepção. A recepção abre a ficha do paciente normalmente, que é o que ela precisa para receber quem chega. Cada profissional enxerga só a própria agenda, e mexer no cadastro e na configuração da clínica fica com a dona e a administração.'
	},
	{
		id: 'pacotes',
		pergunta: 'Como funcionam os pacotes de sessões?',
		resposta:
			'Você monta o pacote com o número de sessões, distribui a grade fixa da semana e a Cinetra vai marcando o que foi usado. O contador aparece na ficha do paciente e o aviso de renovação chega antes de a última sessão acontecer. Você decide se falta sem aviso consome sessão do pacote.'
	},
	{
		id: 'unidades',
		pergunta: 'Tenho mais de uma unidade. Dá para usar na mesma conta?',
		resposta:
			'Dá. Cada unidade tem a própria agenda, a própria equipe e os próprios pacientes, e quem atende em mais de uma troca de unidade sem sair do sistema nem ter um segundo login.'
	},
	{
		id: 'cancelar',
		pergunta: 'Posso cancelar quando quiser?',
		resposta:
			'Pode, sem multa e sem fidelidade. O acesso segue até o fim do período já pago e você exporta os seus dados antes de sair. Prontuário tem prazo legal de guarda, então parte do histórico não pode simplesmente ser apagada; a gente explica o que isso significa no seu caso.'
	}
] as const;

/**
 * Dados estruturados da landing (schema.org), em JSON-LD.
 *
 * **Sem `aggregateRating` de propósito.** A página exibe "4,9/5 avaliação das clínicas" como
 * texto de marketing; publicar isso como dado estruturado seria declarar avaliação agregada
 * sem review verificável por trás — a política de rich results do Google trata isso como
 * spam estrutural, e a punição atinge o site inteiro, não só o trecho. O mesmo vale para o
 * depoimento (`Review`) enquanto for texto ilustrativo.
 *
 * Os preços espelham o que a página mostra ao carregar (cobrança anual, o padrão do toggle):
 * dado estruturado que discorda do preço visível é motivo de ação manual.
 */
export function jsonLd(origem: string) {
	const organizacao = {
		'@type': 'Organization',
		'@id': `${origem}/#organizacao`,
		name: SITE.nome,
		url: `${origem}/`,
		description: SITE.descricao,
		// O WORDMARK (`scripts/icons.mjs` → `static/logo.png`), não o símbolo: quem consome este
		// campo é o painel de conhecimento do Google, que mostra a marca a quem ainda não a
		// reconhece. Sem `sameAs` — os perfis sociais não existem, e apontar para perfil que não
		// é da empresa é pior do que não declarar dono nenhum.
		logo: `${origem}/logo.png`
	};

	return {
		'@context': 'https://schema.org',
		'@graph': [
			organizacao,
			{
				'@type': 'WebSite',
				'@id': `${origem}/#site`,
				url: `${origem}/`,
				name: SITE.nome,
				inLanguage: SITE.idioma,
				publisher: { '@id': organizacao['@id'] }
			},
			{
				'@type': 'SoftwareApplication',
				name: SITE.nome,
				applicationCategory: 'BusinessApplication',
				applicationSubCategory: 'Gestão de clínicas',
				operatingSystem: 'Web',
				url: `${origem}/`,
				inLanguage: SITE.idioma,
				description: SITE.descricao,
				publisher: { '@id': organizacao['@id'] },
				featureList: [
					'Agenda com detecção automática de conflitos',
					'Pacotes de sessões com aviso de renovação',
					'Confirmação e lembrete de consulta no WhatsApp',
					'Fila de espera com oferta automática de vaga',
					'Relatórios de ocupação e faltas'
				],
				offers: [
					{
						'@type': 'Offer',
						name: 'Profissional',
						description: 'Para autônomos e consultórios individuais. Preço mensal na cobrança anual.',
						price: '149',
						priceCurrency: 'BRL',
						category: 'subscription'
					},
					{
						'@type': 'Offer',
						name: 'Clínica',
						description: 'Para clínicas com equipe e recepção. Preço mensal na cobrança anual.',
						price: '289',
						priceCurrency: 'BRL',
						category: 'subscription'
					}
				]
			},
			{
				// Derivado do MESMO array que desenha a seção — ver o comentário de `FAQ`.
				//
				// Nota de expectativa: desde agosto de 2023 o Google só exibe rich result de FAQ
				// para sites governamentais e de saúde reconhecidamente autoritativos, então este
				// bloco **não** vai render caixinha sanfonada no resultado da busca. Fica porque é
				// dado correto e barato (~1 KB), lido por outros buscadores e pelos rastreadores
				// que alimentam resposta de IA. O ganho da seção é o texto, não a marcação.
				'@type': 'FAQPage',
				'@id': `${origem}/#duvidas`,
				inLanguage: SITE.idioma,
				mainEntity: FAQ.map(({ pergunta, resposta }) => ({
					'@type': 'Question',
					name: pergunta,
					acceptedAnswer: { '@type': 'Answer', text: resposta }
				}))
			}
		]
	};
}
