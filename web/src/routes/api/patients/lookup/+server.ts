import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { apiFetch } from '$lib/server/api';
import type { Patient } from '$lib/patients';

// Lookup pontual de possível duplicado, same-origin pelo BFF (ADR-005). Dois modos:
//
//   * `?q=` — CPF/telefone com dígitos completos (o modo original);
//   * `?nome=&nascimento=` — AN-10 (HOM-013, resto): o cadastro feito SEM documento. A API
//     busca por nome (`?q=` da lista) e **este** endpoint recorta por nascimento igual — a
//     lista não filtra por data, e com `limit=5` o recorte aqui é barato.
//
// Substitui o carrega-tudo que a ficha fazia: antes, `/pacientes/novo` e `/editar` baixavam o
// cadastro INTEIRO da clínica só para avisar "possível duplicado" no cliente. Agora a busca é
// do servidor e volta só o mínimo do aviso — e só dispara com termo completo o bastante para
// identificar, então é uma consulta rara e barata.
//
// Sem sessão a API responde 401 e devolvemos lista vazia: o aviso é conveniência, nunca uma
// barreira (a decisão da fatia é "só avisar, não barrar" — a AN-11 barra FORMATO, não duplicado).
export const GET: RequestHandler = async (event) => {
	const q = event.url.searchParams.get('q')?.trim() ?? '';
	const digits = q.replace(/\D/g, '');

	if (digits.length >= 10) return buscar(event, digits, () => true);

	const nome = event.url.searchParams.get('nome')?.trim() ?? '';
	const nascimento = event.url.searchParams.get('nascimento') ?? '';

	if (nome.length >= 3 && /^\d{4}-\d{2}-\d{2}$/.test(nascimento)) {
		return buscar(event, nome, (p) => p.nascimento === nascimento);
	}

	return json({ matches: [] });
};

async function buscar(
	event: Parameters<RequestHandler>[0],
	termo: string,
	recorte: (p: Patient) => boolean
) {
	try {
		const res = await apiFetch(event, `/api/patients?${new URLSearchParams({ q: termo, limit: '5' })}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return json({ matches: [] });

		const body = (await res.json()) as { patients?: Patient[] };
		const matches = (body.patients ?? []).filter(recorte).map((p) => ({
			id: p.id,
			nome: p.nome,
			cpf: p.cpf,
			tel: p.tel
		}));

		return json({ matches });
	} catch {
		return json({ matches: [] });
	}
}
