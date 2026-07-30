import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { apiFetch } from '$lib/server/api';
import type { Patient } from '$lib/patients';
import { canonizarTelefone } from '$lib/telefone';

// Aviso de possível duplicado, same-origin pelo BFF (ADR-005). Recebe a identificação da ficha
// sendo digitada e devolve **o primeiro** cadastro que já tem um daqueles valores:
//
//   GET /api/patients/lookup?cpf=&tel=&email=&nome=&nascimento=&exclude=<id>
//   → { match: { id, nome, campo, ativo } | null }
//
// Desde 2026-07-29 identificação repetida **barra** no save (as `identities` de `Api.Records`).
// Isso mudou o papel deste endpoint: ele deixou de ser conveniência ("olha, talvez seja a mesma
// pessoa") e passou a ser o aviso que evita digitar a ficha inteira para levar um 422 no fim. Por
// isso ele confere os TRÊS campos que barram, e não um só.
//
// ## O bug que este desenho conserta
//
// Antes, o cliente escolhia **um** termo e mandava `?q=`, com o CPF na frente. Consequência: com
// o CPF preenchido e sem colisão, telefone repetido não era consultado — nenhum aviso, e a recusa
// só aparecia no save. Quem decide o que conferir é este módulo, que vê todos os campos de uma vez.
//
// ## Por que o recorte canônico daqui é obrigatório
//
// A busca da API é `LIKE %termo%` (substring). Ela devolve vizinhos: um fixo de 10 dígitos é
// sufixo de vários celulares, e "45678" casa vários CPFs. Comparar aqui a forma **canônica** dos
// dois lados é o que separa "é a mesma pessoa" de "casou por acaso".
//
// Sem sessão a API responde 401 e devolvemos `match: null`: o aviso nunca é a barreira — quem
// recusa é o servidor, com o campo e a mensagem.
export const GET: RequestHandler = async (event) => {
	const p = event.url.searchParams;
	const exclude = p.get('exclude') ?? '';

	// A ordem é a do aviso: o CPF identifica melhor que o telefone, que identifica melhor que o
	// e-mail. Todas as sondas rodam (é a correção do bug); o que a ordem decide é qual campo a
	// tela cita quando mais de um colide.
	const sondas = [
		sondaCpf(p.get('cpf')),
		sondaTel(p.get('tel')),
		sondaEmail(p.get('email'))
	].filter(Boolean) as Sonda[];

	// Nome + nascimento é a heurística de quem NÃO tem documento (AN-10): com identificação
	// preenchida ela só gastaria uma consulta a mais para dizer o que o CPF já disse.
	const usadas = sondas.length
		? sondas
		: ([sondaNomeNascimento(p.get('nome'), p.get('nascimento'))].filter(Boolean) as Sonda[]);

	for (const sonda of usadas) {
		const hit = await buscar(event, sonda, exclude);
		if (hit) return json({ match: hit });
	}

	return json({ match: null });
};

interface Sonda {
	termo: string;
	campo: string;
	casa: (p: Patient) => boolean;
}

const digitos = (v: string): string => v.replace(/\D/g, '');

function sondaCpf(valor: string | null): Sonda | null {
	const d = digitos(valor ?? '');
	if (d.length !== 11) return null;

	return { termo: d, campo: 'CPF', casa: (p) => digitos(p.cpf ?? '') === d };
}

function sondaTel(valor: string | null): Sonda | null {
	const canonico = canonizarTelefone(valor);
	if (!canonico) return null;

	// O termo da busca são os dígitos nacionais (é o que a coluna guarda em fichas antigas e o que
	// o `regexp_replace` do backend compara); a igualdade é sobre o canônico.
	return {
		termo: digitos(valor ?? ''),
		campo: 'celular',
		casa: (p) => canonizarTelefone(p.tel) === canonico
	};
}

function sondaEmail(valor: string | null): Sonda | null {
	const email = (valor ?? '').trim().toLowerCase();
	// A mesma forma mínima que a `CampoValido` do backend exige — abaixo dela não há o que buscar.
	if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;

	return {
		termo: email,
		campo: 'e-mail',
		casa: (p) => (p.email ?? '').trim().toLowerCase() === email
	};
}

function sondaNomeNascimento(nome: string | null, nascimento: string | null): Sonda | null {
	const termo = (nome ?? '').trim();
	const data = nascimento ?? '';
	if (termo.length < 3 || !/^\d{4}-\d{2}-\d{2}$/.test(data)) return null;

	// A busca da API não filtra por data; o recorte por nascimento igual é daqui.
	return {
		termo,
		campo: 'nome e data de nascimento',
		casa: (p) => p.nascimento === data
	};
}

async function buscar(event: Parameters<RequestHandler>[0], sonda: Sonda, exclude: string) {
	try {
		const qs = new URLSearchParams({ q: sonda.termo, limit: '5' });
		const res = await apiFetch(event, `/api/patients?${qs}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return null;

		const body = (await res.json()) as { patients?: Patient[] };
		const hit = (body.patients ?? []).find((p) => p.id !== exclude && sonda.casa(p));

		// Só o mínimo do aviso: nome (para dizer de quem é), se está arquivada (para mandar reativar
		// em vez de recadastrar) e o id. Nada de campo de ficha — quem consulta é o formulário de
		// cadastro, que não deve receber a ficha de outra pessoa de brinde.
		return hit ? { id: hit.id, nome: hit.nome, campo: sonda.campo, ativo: hit.ativo } : null;
	} catch {
		// Rede fora: o aviso é conveniência, nunca barreira — segue sem avisar.
		return null;
	}
}
