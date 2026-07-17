// Consulta de CEP pelo cliente, via BFF (`/api/cep/:cep`, que fala com o ViaCEP — o CSP
// `connect-src: 'self'` impede o browser de ir direto). Espelha o `lookupCep` do protótipo
// (:1940): só dispara com 8 dígitos e devolve um status para a UI + o endereço quando ok.

export type CepStatus = 'loading' | 'ok' | 'notfound' | 'error' | null;

export interface CepAddress {
	endereco: string;
	bairro: string;
	cidade: string;
	uf: string;
}

export async function lookupCep(
	cep: string
): Promise<{ status: Exclude<CepStatus, 'loading'>; address?: CepAddress }> {
	const digits = cep.replace(/\D/g, '');
	if (digits.length !== 8) return { status: null };

	try {
		const res = await fetch(`/api/cep/${digits}`);
		if (res.status === 404) return { status: 'notfound' };
		if (!res.ok) return { status: 'error' };
		return { status: 'ok', address: (await res.json()) as CepAddress };
	} catch {
		return { status: 'error' };
	}
}
