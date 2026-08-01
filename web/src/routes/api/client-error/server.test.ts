import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { POST } from './+server';

/**
 * Este endpoint aceita dado de código que roda na máquina de outra pessoa — é a única rota do BFF
 * com essa propriedade. Os testes abaixo são sobre as guardas, não sobre o caminho feliz.
 */

let saida: string[];

function evento(corpo: unknown, extra: Record<string, unknown> = {}) {
	const texto = typeof corpo === 'string' ? corpo : JSON.stringify(corpo);

	return {
		request: new Request('http://localhost/api/client-error', {
			method: 'POST',
			headers: { 'content-type': 'application/json', 'user-agent': 'Vitest', ...(extra.headers as object) },
			body: texto
		}),
		getClientAddress: () => (extra.ip as string) ?? `ip-${Math.random()}`
	} as never;
}

beforeEach(() => {
	saida = [];
	vi.spyOn(console, 'log').mockImplementation((linha: string) => void saida.push(linha));
});

afterEach(() => vi.restoreAllMocks());

describe('POST /api/client-error', () => {
	it('registra o erro e responde 204 sem corpo', async () => {
		const res = await POST(evento({ origem: 'window', message: 'boom', route: '/agenda' }));

		expect(res.status).toBe(204);
		expect(saida).toHaveLength(1);

		const registrado = JSON.parse(saida[0]);
		expect(registrado.severity).toBe('error');
		expect(registrado.message).toBe('erro no browser');
		expect(registrado.detail).toBe('boom');
		expect(registrado.origem).toBe('window');
	});

	it('sanitiza UUID DENTRO do stack, não só no campo route', async () => {
		// Pego ao rodar o pipeline de verdade: `route` saía como `/pacientes/:id` mas o stack ia
		// inteiro, com o id do paciente dentro — a URL da página aparece em todo stack de browser.
		// Sanitizar só o campo estruturado dava a impressão de barreira sem a barreira.
		await POST(
			evento({
				message: 'erro em /pacientes/019f7c5b-1bee-7a32-9fad-c3d6f0a83177',
				stack: 'at Agenda (/pacientes/019f7c5b-1bee-7a32-9fad-c3d6f0a83177)',
				route: '/agenda'
			})
		);

		expect(saida[0]).not.toContain('019f7c5b');
		const registrado = JSON.parse(saida[0]);
		expect(registrado.stack).toContain(':id');
		expect(registrado.detail).toContain(':id');
	});

	it('RE-sanitiza a rota — a barreira não pode depender do cliente', async () => {
		// O `hooks.client.ts` já sanitiza, mas ele roda no browser e o usuário consegue editá-lo.
		// Quem garante é este lado.
		await POST(evento({ message: 'x', route: '/pacientes/019f7c5b-1bee-7a32-9fad-c3d6f0a83177' }));

		const registrado = JSON.parse(saida[0]);
		expect(registrado.route).toBe('/pacientes/:id');
		expect(saida[0]).not.toContain('019f7c5b');
	});

	it('ignora campo fora da allowlist', async () => {
		// Sem allowlist, um cliente injetaria campo arbitrário no log — inclusive `severity`,
		// para se esconder de uma consulta por erro.
		await POST(
			evento({
				message: 'x',
				severity: 'info',
				service: 'api',
				campo_inventado: 'lixo',
				cpf: '111.222.333-44'
			})
		);

		const registrado = JSON.parse(saida[0]);
		expect(registrado.severity).toBe('error');
		expect(registrado.service).toBe('web');
		expect(registrado.campo_inventado).toBeUndefined();
		expect(saida[0]).not.toContain('111.222.333-44');
	});

	it('trunca stack acima do limite de campo', async () => {
		// 4 KB passa pelo teto de corpo (8 KB) mas excede o limite do campo (2 KB), então exercita
		// a truncagem — que é o que impede um erro em laço de encher a retenção do dia.
		await POST(evento({ message: 'x', stack: 'z'.repeat(4000) }));

		const registrado = JSON.parse(saida[0]);
		expect(registrado.stack.length).toBeLessThan(2100);
		expect(registrado.stack).toContain('…');
	});

	it('recusa corpo grande — mas REGISTRA que ele existiu', async () => {
		const res = await POST(
			evento({ message: 'x' }, { headers: { 'content-length': String(999_999) } })
		);

		expect(res.status).toBe(413);

		// Descartar calado perderia o sinal mais interessante: o cliente trunca em 2 KB, então
		// corpo acima do teto é cliente modificado, laço ou abuso.
		expect(saida).toHaveLength(1);
		const registrado = JSON.parse(saida[0]);
		expect(registrado.severity).toBe('warning');
		expect(registrado.bytes).toBe(999_999);
	});

	it('recusa JSON inválido — e também registra', async () => {
		const res = await POST(evento('{{{ isto não é json'));

		expect(res.status).toBe(400);
		// JSON quebrado vindo do nosso próprio cliente é bug nosso, e some se ninguém registrar.
		expect(saida).toHaveLength(1);
		expect(JSON.parse(saida[0]).severity).toBe('warning');
	});

	it('limita por IP — um laço no browser não pode encher a retenção', async () => {
		const ip = 'ip-fixo-do-teste';
		let bloqueados = 0;

		for (let i = 0; i < 40; i++) {
			const res = await POST(evento({ message: `erro ${i}` }, { ip }));
			if (res.status === 429) bloqueados++;
		}

		expect(bloqueados).toBeGreaterThan(0);
		expect(saida.length).toBeLessThanOrEqual(20);
	});

	it('o limite é POR IP — um cliente ruidoso não silencia os outros', async () => {
		const ruidoso = 'ip-ruidoso';
		for (let i = 0; i < 40; i++) await POST(evento({ message: `e${i}` }, { ip: ruidoso }));

		const antes = saida.length;
		const res = await POST(evento({ message: 'de outro cliente' }, { ip: 'ip-limpo' }));

		expect(res.status).toBe(204);
		expect(saida.length).toBe(antes + 1);
	});
});

describe('POST /api/client-error — agrupamento (doc 98 §opção C)', () => {
	// Afirma a PRESENÇA antes de devolver. Sem isto, os testes de igualdade abaixo passariam com o
	// campo ausente — `undefined === undefined` é verde, e quatro deles deram verde antes de a
	// implementação existir. Um teste que passa sem o código é pior que nenhum.
	function fingerprintDe(linha: string): string {
		const f = JSON.parse(linha).fingerprint;
		expect(f, 'o evento não tem campo fingerprint').toBeTypeOf('string');
		expect(f.length, 'fingerprint vazio').toBeGreaterThan(0);
		return f;
	}

	it('carimba um fingerprint no evento', async () => {
		await POST(
			evento({ origem: 'kit', message: 'x', stack: 'Error: x\n    at foo (https://a/b.ts:1:2)' })
		);
		expect(fingerprintDe(saida[0])).toMatch(/^[a-z0-9]+$/);
	});

	it('o MESMO problema em ocorrências diferentes recebe o mesmo fingerprint', async () => {
		await POST(
			evento({ origem: 'kit', message: 'x', stack: 'Error: x\n    at foo (https://a/b.ts:1:2)' })
		);
		await POST(
			evento({ origem: 'kit', message: 'x', stack: 'Error: x\n    at foo (https://a/b.ts:9:9)' })
		);
		expect(fingerprintDe(saida[0])).toBe(fingerprintDe(saida[1]));
	});

	it('problemas diferentes recebem fingerprints diferentes', async () => {
		await POST(evento({ origem: 'kit', message: 'a', stack: 'Error\n    at foo (https://a/b.ts:1:2)' }));
		await POST(evento({ origem: 'kit', message: 'b', stack: 'Error\n    at bar (https://a/c.ts:1:2)' }));
		expect(fingerprintDe(saida[0])).not.toBe(fingerprintDe(saida[1]));
	});

	// A propriedade que sustenta o desenho. O cliente também calcula o fingerprint (para deduplicar
	// antes de enviar), mas o valor dele NUNCA é aceito: o servidor recomputa dos campos recebidos.
	// Sem isto, um cliente modificado escolheria em qual grupo cair — podendo esconder um erro novo
	// dentro de um grupo velho e ruidoso, que é o jeito mais barato de tornar um bug invisível.
	it('IGNORA fingerprint vindo do cliente — recomputa do zero', async () => {
		await POST(
			evento({
				origem: 'kit',
				message: 'x',
				stack: 'Error: x\n    at foo (https://a/b.ts:1:2)',
				fingerprint: 'forjado-pelo-cliente'
			})
		);
		expect(fingerprintDe(saida[0])).not.toBe('forjado-pelo-cliente');
	});

	// O fingerprint é calculado sobre o stack JÁ sanitizado. Se fosse sobre o cru, dois relatos do
	// mesmo bug em fichas de pacientes diferentes teriam stacks diferentes (o uuid está na URL
	// dentro do stack) e cairiam em grupos separados — o agrupamento morreria justamente na tela
	// que mais gera erro.
	it('agrupa o mesmo bug em fichas de pacientes diferentes', async () => {
		const stackDe = (id: string) =>
			`TypeError: x\n    at Ficha (https://app/pacientes/${id}/ficha.js:1:2)`;

		await POST(
			evento({
				origem: 'kit',
				message: 'x',
				stack: stackDe('019fab79-6a3d-77f1-8877-f55dab684566')
			})
		);
		await POST(
			evento({
				origem: 'kit',
				message: 'x',
				stack: stackDe('019fab68-3032-77cb-9618-0824a7327765')
			})
		);

		expect(fingerprintDe(saida[0])).toBe(fingerprintDe(saida[1]));
	});
});
