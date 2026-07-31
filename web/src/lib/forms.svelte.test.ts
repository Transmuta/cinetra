import { describe, it, expect, vi } from 'vitest';
import { flushSync } from 'svelte';
import type { ActionResult, SubmitFunction } from '@sveltejs/kit';
import {
	envio,
	envioPorItem,
	reagirAoForm,
	ERRO_DE_REDE,
	type ResultadoDeAction
} from './forms.svelte';

// O `use:enhance` chama a `SubmitFunction` com o contexto do submit e, quando a resposta volta,
// o callback que ela devolveu. Estes dois helpers rodam esse ciclo à mão — é o que permite
// observar o "em voo" no meio dele, que é o instante inteiro que os helpers existem para cobrir.
type Callback = (arg: {
	result: ActionResult;
	update: (o?: { reset?: boolean }) => Promise<void>;
}) => Promise<void>;

const OK: ActionResult = { type: 'success', status: 200 };

function disparar(submit: SubmitFunction, extra: Record<string, unknown> = {}): Callback {
	return submit({ ...extra } as never) as unknown as Callback;
}

describe('envio — um form', () => {
	it('marca em voo durante o POST e solta só depois do update', async () => {
		const e = envio();
		expect(e.emVoo).toBe(false);

		const cb = disparar(e.submit);
		expect(e.emVoo).toBe(true);

		// O `emVoo` cai DEPOIS do update, não antes: é o `update` que traz a tela nova, e soltar o
		// botão antes reabre a janela de reclique com a lista ainda velha.
		let duranteUpdate: boolean | undefined;
		await cb({
			result: OK,
			update: async () => {
				duranteUpdate = e.emVoo;
			}
		});

		expect(duranteUpdate).toBe(true);
		expect(e.emVoo).toBe(false);
	});

	it('repassa o reset do SvelteKit por padrão, e o `false` quando pedido', async () => {
		const update = vi.fn();

		await disparar(envio().submit)({ result: OK, update });
		expect(update).toHaveBeenCalledWith({ reset: true });

		await disparar(envio({ reset: false }).submit)({ result: OK, update });
		expect(update).toHaveBeenLastCalledWith({ reset: false });
	});

	it('chama o aoResponder com o resultado, depois do update', async () => {
		const ordem: string[] = [];
		const e = envio({
			aoResponder: (result) => {
				ordem.push(`responder:${result.type}`);
			}
		});

		await disparar(e.submit)({
			result: OK,
			update: async () => {
				ordem.push('update');
			}
		});

		expect(ordem).toEqual(['update', 'responder:success']);
	});

	// Sem o `finally`, uma falha de rede no meio do `update` deixaria o botão travado para sempre
	// — a tela inteira ficaria sem a ação, e só o F5 a devolveria.
	it('solta o botão mesmo se o update estourar', async () => {
		const e = envio();
		const cb = disparar(e.submit);

		await expect(
			cb({
				result: OK,
				update: async () => {
					throw new Error('rede fora');
				}
			})
		).rejects.toThrow('rede fora');

		expect(e.emVoo).toBe(false);
	});
});

describe('envioPorItem — N forms numa lista', () => {
	it('gira só a linha clicada', async () => {
		const linha = envioPorItem<string>();
		expect(linha.algumEmVoo).toBe(false);

		const cb = disparar(linha.submit('b'));
		expect(linha.emVoo('b')).toBe(true);
		expect(linha.emVoo('a')).toBe(false);
		expect(linha.algumEmVoo).toBe(true);

		await cb({ result: OK, update: async () => {} });
		expect(linha.emVoo('b')).toBe(false);
		expect(linha.algumEmVoo).toBe(false);
	});

	// Um form, vários botões `name`/`value` (a página pública de confirmação): a chave tem de sair
	// do botão CLICADO, senão os dois giram juntos e a pessoa não sabe qual resposta mandou.
	it('submitPeloBotao tira a chave do botão que submeteu', async () => {
		const linha = envioPorItem<string>();
		const botao = document.createElement('button');
		botao.value = 'quer_remarcar';

		const cb = disparar(linha.submitPeloBotao, { submitter: botao });
		expect(linha.emVoo('quer_remarcar')).toBe(true);
		expect(linha.emVoo('confirmou')).toBe(false);

		await cb({ result: OK, update: async () => {} });
		expect(linha.algumEmVoo).toBe(false);
	});

	// Forms escondidos com `requestSubmit()` (o drawer da agenda): a chave só existe depois do
	// clique. Se fosse lida no mount, seria sempre a de antes — ou nenhuma.
	it('submitDinamico lê a chave na hora do clique, não no mount', async () => {
		const linha = envioPorItem<string>();
		let alvo = '';

		const submit = linha.submitDinamico(() => alvo);

		alvo = 'paciente-2:no_show';
		const cb = disparar(submit);
		expect(linha.emVoo('paciente-2:no_show')).toBe(true);

		await cb({ result: OK, update: async () => {} });
		expect(linha.algumEmVoo).toBe(false);
	});
});

// ---------------------------------------------------------------------------------------------
// Rede fora (doc 88 · A-10)
// ---------------------------------------------------------------------------------------------
//
// O bug que estes testes trancam: `update()` chama o `applyAction`, e para `result.type ===
// 'error'` isso troca a página inteira pela tela de erro — levando junto tudo o que a pessoa
// digitou. Medido na ficha do paciente: `500 — Algo deu errado / Failed to fetch`, com os 31
// campos perdidos. A asserção que importa aqui é a NEGATIVA: `update` não pode ser chamado.

const ERRO: ActionResult = { type: 'error', error: new Error('Failed to fetch') };

describe('envio — a rede caiu no meio do POST', () => {
	it('NÃO chama update (é ele que troca a página) e expõe a frase', async () => {
		const e = envio();
		let chamouUpdate = false;

		const cb = disparar(e.submit);
		await cb({
			result: ERRO,
			update: async () => {
				chamouUpdate = true;
			}
		});

		expect(chamouUpdate).toBe(false);
		expect(e.erroRede).toBe(ERRO_DE_REDE);
		// E o botão volta a funcionar: sem isto a pessoa fica com a tela travada.
		expect(e.emVoo).toBe(false);
	});

	it('não roda `aoResponder` — não houve resposta para reagir', async () => {
		const aoResponder = vi.fn();
		const e = envio({ aoResponder });

		await disparar(e.submit)({ result: ERRO, update: async () => {} });

		expect(aoResponder).not.toHaveBeenCalled();
	});

	it('a frase some no envio seguinte', async () => {
		const e = envio();

		await disparar(e.submit)({ result: ERRO, update: async () => {} });
		expect(e.erroRede).toBe(ERRO_DE_REDE);

		disparar(e.submit);
		expect(e.erroRede).toBeNull();
	});
});

describe('envioPorItem — a rede caiu no meio do POST', () => {
	it('NÃO chama update, expõe a frase e solta a linha', async () => {
		const linha = envioPorItem<string>();
		let chamouUpdate = false;

		const cb = disparar(linha.submit('pkg-1'));
		await cb({
			result: ERRO,
			update: async () => {
				chamouUpdate = true;
			}
		});

		expect(chamouUpdate).toBe(false);
		expect(linha.erroRede).toBe(ERRO_DE_REDE);
		expect(linha.algumEmVoo).toBe(false);
	});
});

/**
 * A guarda de identidade é o valor real deste helper: **cinco das sete telas não a tinham**
 * (doc 94 §3.2), e sem ela um `form` já tratado retoasta a cada rerender — ou, se o handler
 * escrever estado que o efeito lê, estoura `effect_update_depth_exceeded` e derruba a tela.
 */
describe('reagirAoForm', () => {
	/** Roda `fn` dentro de um escopo de efeito e devolve o `flush` + o descarte. */
	function comEfeitos(fn: () => void) {
		const descartar = $effect.root(fn);
		flushSync();
		return descartar;
	}

	it('chama `sucesso` quando ok, `erro` quando não', () => {
		let form = $state<ResultadoDeAction | null>(null);
		const sucesso = vi.fn();
		const erro = vi.fn();

		const descartar = comEfeitos(() => reagirAoForm(() => form, { sucesso, erro }));

		form = { ok: true, action: 'criar' };
		flushSync();
		expect(sucesso).toHaveBeenCalledWith({ ok: true, action: 'criar' });
		expect(erro).not.toHaveBeenCalled();

		form = { ok: false, action: 'criar', error: 'não deu' };
		flushSync();
		expect(erro).toHaveBeenCalledWith({ ok: false, action: 'criar', error: 'não deu' });

		descartar();
	});

	it('sem `form` não chama nada — o efeito roda no mount de toda tela', () => {
		const sucesso = vi.fn();
		const erro = vi.fn();

		const descartar = comEfeitos(() => reagirAoForm(() => null, { sucesso, erro }));

		expect(sucesso).not.toHaveBeenCalled();
		expect(erro).not.toHaveBeenCalled();

		descartar();
	});

	/** O caso que a guarda existe para cobrir: o MESMO objeto não é um resultado novo. */
	it('o mesmo resultado não é tratado duas vezes', () => {
		const mesmo: ResultadoDeAction = { ok: true, action: 'criar' };
		let gatilho = $state(0);
		const sucesso = vi.fn();

		const descartar = comEfeitos(() =>
			reagirAoForm(
				() => {
					gatilho; // dependência extra: força o efeito a rodar de novo
					return mesmo;
				},
				{ sucesso }
			)
		);

		expect(sucesso).toHaveBeenCalledTimes(1);

		gatilho = 1;
		flushSync();
		gatilho = 2;
		flushSync();

		expect(sucesso).toHaveBeenCalledTimes(1);

		descartar();
	});

	it('mas um resultado NOVO com o mesmo conteúdo é tratado', () => {
		let form = $state<ResultadoDeAction | null>({ ok: true, action: 'criar' });
		const sucesso = vi.fn();

		const descartar = comEfeitos(() => reagirAoForm(() => form, { sucesso }));
		expect(sucesso).toHaveBeenCalledTimes(1);

		form = { ok: true, action: 'criar' };
		flushSync();
		expect(sucesso).toHaveBeenCalledTimes(2);

		descartar();
	});

	/**
	 * O crash medido: o handler escreve num `$state` que a própria tela lê. Com a guarda como
	 * `$state`, isto era `effect_update_depth_exceeded`.
	 */
	it('handler que escreve estado não realimenta o efeito', () => {
		let form = $state<ResultadoDeAction | null>(null);
		let modalAberto = $state(true);
		// Lido por closure, e não direto: `expect(modalAberto)` capturaria o valor do primeiro
		// render e o compilador avisa (`state_referenced_locally`) — com razão.
		const aberto = () => modalAberto;

		const descartar = comEfeitos(() =>
			reagirAoForm(() => form, {
				sucesso: () => {
					modalAberto = false;
				}
			})
		);

		form = { ok: true, action: 'criar' };
		expect(() => flushSync()).not.toThrow();
		expect(aberto()).toBe(false);

		descartar();
	});
});
