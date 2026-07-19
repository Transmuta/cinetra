import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { apiFetch } from '$lib/server/api';
import type { Patient } from '$lib/patients';

// Lookup pontual de possível duplicado (CPF/telefone), same-origin pelo BFF (ADR-005).
//
// Substitui o carrega-tudo que a ficha fazia: antes, `/pacientes/novo` e `/editar` baixavam o
// cadastro INTEIRO da clínica só para avisar "possível duplicado" no cliente. Agora a busca é
// do servidor (a mesma `?q=` da lista) e volta só o mínimo do aviso — e só dispara quando o
// documento está completo, então é uma consulta rara e barata.
//
// Sem sessão a API responde 401 e devolvemos lista vazia: o aviso é conveniência, nunca uma
// barreira (a decisão da fatia é "só avisar, não barrar").
export const GET: RequestHandler = async (event) => {
	const q = event.url.searchParams.get('q')?.trim() ?? '';
	const digits = q.replace(/\D/g, '');

	// Só vale a pena consultar com documento/telefone completo o bastante para identificar.
	if (digits.length < 10) return json({ matches: [] });

	try {
		const res = await apiFetch(event, `/api/patients?q=${encodeURIComponent(digits)}&limit=5`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return json({ matches: [] });

		const body = (await res.json()) as { patients?: Patient[] };
		const matches = (body.patients ?? []).map((p) => ({
			id: p.id,
			nome: p.nome,
			cpf: p.cpf,
			tel: p.tel
		}));

		return json({ matches });
	} catch {
		return json({ matches: [] });
	}
};
