// Telefone brasileiro: canônico no banco, mascarado na tela.
//
// O backend guarda em E.164 (`+5511987654321`) desde o doc 52 §9, porque é a forma que o opt-out
// compara e que a Zernio recebe. Ninguém lê `+5511987654321` num balcão, então a máscara é da
// leitura — a mesma divisão de `cnpj.ts` e `cep.ts`.

/** `+5511987654321` → `(11) 98765-4321`. O que não for reconhecido volta como veio. */
export function formatarTelefone(valor: string | null | undefined): string | null {
	if (!valor) return null;

	// Número internacional que não é do Brasil sai intocado. Sem esta linha, `+1 415 555 0000`
	// (11 dígitos, como um celular nosso) virava `(14) 15555-0000` — o teste pegou. A ficha aceita
	// texto livre desde antes da normalização, então estrangeiro na base existe.
	if (valor.trim().startsWith('+') && !valor.replace(/\D/g, '').startsWith('55')) return valor;

	const digitos = valor.replace(/\D/g, '');
	const nacional = digitos.startsWith('55') && digitos.length >= 12 ? digitos.slice(2) : digitos;

	// Celular: DDD + 9 dígitos. Fixo: DDD + 8.
	if (nacional.length === 11)
		return `(${nacional.slice(0, 2)}) ${nacional.slice(2, 7)}-${nacional.slice(7)}`;
	if (nacional.length === 10)
		return `(${nacional.slice(0, 2)}) ${nacional.slice(2, 6)}-${nacional.slice(6)}`;

	return valor;
}

/**
 * O telefone é **aceitável para salvar**? Espelho literal de
 * `Api.Messaging.Dispatch.normalizar(:whatsapp, _)`, que é quem a `Api.Validations.TelObrigatorio`
 * consulta para aprovar ou recusar a ficha.
 *
 * Existe desde a D6 (doc 64), que tornou o telefone obrigatório em paciente **e** profissional:
 * sem isto, os dois formulários deixavam salvar e o 422 só chegava depois da viagem.
 *
 * Duas bordas que ninguém adivinha, e que são a razão de a regra estar escrita num lugar só:
 *
 *  - **12 ou 13 dígitos também valem**, quando já vêm com o `55`. Um cliente que só aceitasse
 *    10–11 barraria número que o servidor aprova, e a pessoa ficaria presa sem entender por quê;
 *  - **não há a guarda de estrangeiro** que `formatarTelefone` e `recebeWhatsapp` têm. É de
 *    propósito: o servidor não a tem, e um `+1 415 555 0000` (11 dígitos) **passa** na validação
 *    dele. Divergir aqui faria a tela recusar o que o banco aceita — pior que a imprecisão.
 *
 * Como nas outras deste arquivo, o veredito continua sendo do servidor: aqui só se evita a ida.
 */
export function telefoneValido(valor: string | null | undefined): boolean {
	const digitos = (valor ?? '').replace(/\D/g, '');

	if (digitos.length >= 12 && digitos.length <= 13) return digitos.startsWith('55');
	return digitos.length >= 10 && digitos.length <= 11;
}

/**
 * Este número recebe WhatsApp?
 *
 * Só celular (DDD + 9 dígitos começando por 9) — é a mesma regra de
 * `Api.Messaging.Dispatch.celular?/1`, e existe aqui para a tela poder **avisar antes** que a
 * ficha só vai receber por e-mail. Duplicar a regra é deliberado e barato: o servidor continua
 * sendo a autoridade, e o que a tela faz é adiantar a informação, não decidir.
 */
export function recebeWhatsapp(valor: string | null | undefined): boolean {
	if (!valor) return false;

	// Mesma guarda do `formatarTelefone`: número de outro país não é celular brasileiro, e a
	// contagem de dígitos sozinha diria que sim.
	if (valor.trim().startsWith('+') && !valor.replace(/\D/g, '').startsWith('55')) return false;

	const digitos = valor.replace(/\D/g, '');
	const nacional = digitos.startsWith('55') && digitos.length >= 12 ? digitos.slice(2) : digitos;

	return nacional.length === 11 && nacional[2] === '9';
}
