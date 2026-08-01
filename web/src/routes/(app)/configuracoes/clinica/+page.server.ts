import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchClinic, updateClinic } from '$lib/server/clinics';

// Carrega os dados da clínica ativa (BFF → /api/clinic). Como as demais telas de config, NÃO há
// recorte de papel no load: todo membro lê; só a escrita exige owner/admin (policies da API + o
// `canManage` da página).
export const load: PageServerLoad = async (event) => {
	const result = await fetchClinic(event);

	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar os dados da clínica.');
	}

	return { clinic: result.data.clinic };
};

// Os campos opcionais que viajam SEMPRE, mesmo em branco — é assim que se limpa um deles. A lista
// existe uma vez só porque a action e o formulário precisam concordar sobre o que atravessa: um
// campo desenhado na tela e esquecido aqui salva em silêncio e some no recarregamento.
const OPCIONAIS = [
	'cnpj',
	'telefone',
	'cep',
	'endereco',
	'numero',
	'complemento',
	'bairro',
	'cidade',
	'uf'
] as const;

export const actions: Actions = {
	// Identidade, contato e endereço salvos de uma vez. O CNPJ viaja como o usuário digitou
	// (mascarado): a API é a autoridade — normaliza e valida, e um 422 já vira toast de erro.
	//
	// O telefone também vai como digitado, e de propósito: ele é lido por um paciente dentro da
	// mensagem, não discado por máquina.
	save: async (event) => {
		const form = await event.request.formData();
		const nome = String(form.get('nome') ?? '').trim();

		if (nome === '') return fail(400, { error: 'Informe o nome da clínica.' });

		const res = await updateClinic(event, {
			nome,
			...Object.fromEntries(OPCIONAIS.map((c) => [c, String(form.get(c) ?? '').trim()]))
		});

		if (!res.ok) return fail(res.status || 400, { error: res.error });
		return { ok: true };
	}
};
