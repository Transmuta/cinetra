import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

// Proxy de consulta de CEP (ViaCEP), server-side. O CSP do app (`connect-src: 'self'`,
// svelte.config) impede o browser de falar direto com o ViaCEP, então o lookup passa pelo BFF
// (ADR-005): o cliente chama same-origin `/api/cep/:cep` e o SvelteKit consulta o ViaCEP.
// Devolve só os campos de endereço que a ficha preenche; 404 quando o CEP não existe.
interface ViaCep {
	erro?: boolean;
	logradouro?: string;
	bairro?: string;
	localidade?: string;
	uf?: string;
}

export const GET: RequestHandler = async ({ params, fetch }) => {
	const cep = params.cep.replace(/\D/g, '');
	if (cep.length !== 8) error(400, 'CEP inválido');

	let data: ViaCep;
	try {
		const res = await fetch(`https://viacep.com.br/ws/${cep}/json/`);
		data = (await res.json()) as ViaCep;
	} catch {
		error(502, 'Não foi possível consultar o CEP.');
	}

	if (data.erro) error(404, 'CEP não encontrado');

	return json({
		endereco: data.logradouro ?? '',
		bairro: data.bairro ?? '',
		cidade: data.localidade ?? '',
		uf: data.uf ?? ''
	});
};
