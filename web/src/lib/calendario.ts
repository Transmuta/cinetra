// Levar uma sessão para o calendário do paciente — as duas formas, e por que são duas.
//
// ## O que o `.ics` sozinho não resolveu
//
// O desenho original oferecia só um `.ics` servido pelo nosso domínio, com o argumento de que o
// aparelho o entrega ao app de calendário **padrão** — sem mandar quem usa iPhone para uma tela de
// login do Google, e sem contar a um terceiro que essa pessoa tem sessão nesta clínica. O
// argumento continua de pé; o que ele não previu foi o que o navegador do celular faz com o
// arquivo:
//
// - **Android/Chrome** baixa `text/calendar` sempre. O arquivo cai em Downloads, aparece uma
//   notificação, e nada abre. Quem tocou no botão vê acontecer *nada* — foi assim que o problema
//   apareceu, com o produto na mão.
// - **iPhone/Safari** só abre a folha nativa de evento se a resposta **não** for
//   `Content-Disposition: attachment`; com ela, o arquivo vai para o app Arquivos e a pessoa
//   precisa sair do navegador para achá-lo.
//
// Daí as duas correções: a rota do `.ics` passou a servir `inline` (conserta o iPhone), e esta
// função dá ao Android o caminho que de fato abre — o link de template do Google Agenda.
//
// ## O que este link custa em privacidade
//
// A URL leva o título do evento para um domínio do Google. Hoje o título é `Sessão na <clínica>`,
// então quem clica conta ao Google onde se trata — o que o `.ics` no nosso domínio não fazia.
// Ficou assim por decisão explícita (2026-08-05): o botão só existe **depois** de a pessoa
// confirmar presença, e ela escolhe entre os dois links lado a lado. Se um dia isso incomodar, o
// conserto é de uma linha — passar `titulo: 'Sessão'` aqui e deixar o nome da clínica só no
// `.ics`, que não sai do nosso domínio.

export interface EventoAgenda {
	/** Instante ISO (UTC) do começo. `null` quando a API não resolveu a sessão. */
	inicio?: string | null;
	/** Instante ISO (UTC) do fim. */
	fim?: string | null;
	titulo: string;
	descricao?: string;
}

/**
 * O que o evento diz, num lugar só.
 *
 * Título e descrição são montados aqui porque agora têm **dois** consumidores — o `.ics` e o link
 * do Google —, e duas cópias divergiriam no que o paciente lê no calendário meses depois. É o
 * mesmo motivo de `confirmar/[token]/resposta.ts` existir.
 *
 * "Fale com a clínica", e não "ligue": o canal em que ela responde é o WhatsApp, e o evento de
 * calendário não carrega link clicável em todo aplicativo — o número, sim, todo mundo sabe usar.
 */
export function tituloDaSessao(clinica: string | null | undefined): string {
	return `Sessão na ${clinica || 'sua clínica'}`;
}

export function descricaoDaSessao(
	clinica: string | null | undefined,
	telefone: string | null | undefined
): string {
	const nome = clinica || 'sua clínica';
	return telefone
		? `Sua sessão na ${nome}. Precisa remarcar? Fale com a clínica: ${telefone}.`
		: `Sua sessão na ${nome}.`;
}

/**
 * Instante ISO → `AAAAMMDDTHHMMSSZ`.
 *
 * A única forma que dispensa declarar fuso, e a mesma nos dois destinos: é o `DTSTART` do RFC 5545
 * e o `dates` do Google. Mora aqui, e não em `server/ics.ts`, porque aquele arquivo é server-only
 * (usa `node:crypto`) e este link é montado na tela, que roda no browser.
 */
export function utcCompacto(iso: string): string {
	return new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
}

/** `true` só para o que o `Date` conseguiu ler — string vinda da API não é promessa. */
function instante(valor: string | null | undefined): valor is string {
	return !!valor && !Number.isNaN(new Date(valor).getTime());
}

/**
 * Android? Decidido pelo `user-agent` **no servidor**, no `load` da página.
 *
 * No servidor e não no browser pelo mesmo motivo do `quandoDo`: o que é calculado na hidratação
 * diverge do que o SSR pintou, e aqui a divergência seria o `href` do botão trocando debaixo do
 * dedo de quem já ia tocar nele.
 *
 * A checagem é grosseira de propósito. O que ela decide é apenas *qual das duas formas do mesmo
 * link* mandar, e a forma do Android carrega a outra dentro de si como fallback — errar para
 * qualquer lado devolve, no pior caso, o comportamento de hoje.
 */
export function ehAndroid(userAgent: string | null | undefined): boolean {
	return !!userAgent && /android/i.test(userAgent);
}

/**
 * `https://…` → `intent://…`, o endereçamento do Chrome for Android que abre um **pacote**.
 *
 * É o único mecanismo que faz o link cair no aplicativo do Google Agenda em vez do site: o
 * `https://` normal abre o Agenda web dentro do Chrome, como foi medido no aparelho. O
 * `browser_fallback_url` é obrigatório aqui — sem ele, quem não tem o app (ou não usa Chrome)
 * recebe uma página de erro em vez do site.
 */
function intentDoAndroid(url: string): string {
	// O fragmento `#Intent;chave=valor;…;end` é a sintaxe do Chrome; o `;` separa os campos DEPOIS
	// do `#Intent`, e a URL original entra crua antes dele (sem o esquema, que vira `scheme=`).
	const campos = [
		'scheme=https',
		'package=com.google.android.calendar',
		`S.browser_fallback_url=${encodeURIComponent(url)}`,
		'end'
	].join(';');

	return `intent://${url.replace(/^https:\/\//, '')}#Intent;${campos}`;
}

/**
 * O link que abre o Google Agenda já com o evento preenchido, ou `null` quando não há evento.
 *
 * Devolve `null` (em vez de um link torto) sempre que faltar instante: um evento sem horário
 * aterrissa no Google como "dia inteiro de hoje", que é pior que não oferecer o botão. A tela usa
 * esse `null` para não desenhar o link — é a mesma régua do telefone da clínica.
 */
export function linkGoogleAgenda(
	evento: EventoAgenda | null | undefined,
	opcoes: { android?: boolean } = {}
): string | null {
	if (!evento || !instante(evento.inicio) || !instante(evento.fim)) return null;

	const params = new URLSearchParams({ action: 'TEMPLATE', text: evento.titulo });
	if (evento.descricao) params.set('details', evento.descricao);

	// O `dates` é concatenado à mão, e não pelo `URLSearchParams`, porque ele codificaria a barra
	// como `%2F` — e o Google lê isso como um valor só, abrindo um evento sem horário. Os dois
	// lados são apenas dígitos, `T` e `Z`, então não há nada a escapar.
	const datas = `${utcCompacto(evento.inicio)}/${utcCompacto(evento.fim)}`;
	const url = `https://calendar.google.com/calendar/render?${params}&dates=${datas}`;

	return opcoes.android ? intentDoAndroid(url) : url;
}
