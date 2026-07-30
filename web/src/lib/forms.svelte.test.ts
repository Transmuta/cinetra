import { describe, it, expect, vi } from 'vitest';
import type { ActionResult, SubmitFunction } from '@sveltejs/kit';
import { envio, envioPorItem } from './forms.svelte';

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
