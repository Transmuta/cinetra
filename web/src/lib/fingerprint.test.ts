import { describe, it, expect } from 'vitest';
import { fingerprint, _canonizar, _frames } from './fingerprint';

// Stack do Chrome, código da aplicação com nomes de função reais (o que se vê depois do
// source map resolver, e em dev).
const STACK_APP = `TypeError: Cannot read properties of undefined (reading 'nome')
    at renderFicha (https://app.exemplo/src/lib/components/patients/Ficha.svelte:42:17)
    at atualizar (https://app.exemplo/src/lib/agenda.ts:118:9)`;

// O mesmo erro, outra ocorrência: linha/coluna diferentes, id diferente na mensagem.
const STACK_APP_VARIANTE = `TypeError: Cannot read properties of undefined (reading 'nome')
    at renderFicha (https://app.exemplo/src/lib/components/patients/Ficha.svelte:44:23)
    at atualizar (https://app.exemplo/src/lib/agenda.ts:120:11)`;

// Erro DIFERENTE, na mesma tela.
const STACK_OUTRO = `TypeError: x.map is not a function
    at listar (https://app.exemplo/src/lib/components/patients/Ficha.svelte:80:3)`;

describe('fingerprint — camada 1: stack com nomes de função significativos', () => {
	it('agrupa o mesmo erro com linha/coluna diferentes', () => {
		expect(fingerprint('kit', 'erro', STACK_APP)).toBe(
			fingerprint('kit', 'erro', STACK_APP_VARIANTE)
		);
	});

	it('separa erros diferentes na mesma tela', () => {
		expect(fingerprint('kit', 'a', STACK_APP)).not.toBe(fingerprint('kit', 'b', STACK_OUTRO));
	});

	// O passo que separa um fingerprint útil de um inútil. Sem filtrar frame de biblioteca, TODO
	// erro que atravessa o runtime do Svelte compartilha os mesmos frames de topo e agrupa junto —
	// o resultado é um "issue" gigante que não diz nada e some com os outros dentro dele.
	it('IGNORA frames de biblioteca — só o código da aplicação entra no hash', () => {
		const comBiblioteca = `TypeError: erro
    at flushSync (https://app.exemplo/node_modules/svelte/src/internal/client/runtime.js:210:5)
    at update_reaction (https://app.exemplo/node_modules/svelte/src/internal/client/runtime.js:88:9)
    at renderFicha (https://app.exemplo/src/lib/components/patients/Ficha.svelte:42:17)
    at atualizar (https://app.exemplo/src/lib/agenda.ts:118:9)`;

		expect(fingerprint('kit', 'erro', comBiblioteca)).toBe(fingerprint('kit', 'erro', STACK_APP));
	});

	it('dois erros que só compartilham os frames de biblioteca NÃO agrupam', () => {
		const a = `Error: a
    at flushSync (https://app.exemplo/node_modules/svelte/src/internal/client/runtime.js:210:5)
    at umaCoisa (https://app.exemplo/src/lib/a.ts:10:1)`;
		const b = `Error: b
    at flushSync (https://app.exemplo/node_modules/svelte/src/internal/client/runtime.js:210:5)
    at outraCoisa (https://app.exemplo/src/lib/b.ts:10:1)`;

		expect(fingerprint('kit', 'a', a)).not.toBe(fingerprint('kit', 'b', b));
	});
});

describe('fingerprint — camada 2: stack minificado', () => {
	// Sem source map resolvido, os nomes viram uma ou duas letras. Aí a camada 1 não serve: `Ki`
	// não identifica nada. Cai-se para a SEQUÊNCIA DE ARQUIVOS + mensagem canônica.
	const MIN_A = `TypeError: undefined is not an object
    at Ki (https://app.exemplo/_app/immutable/chunks/D3kf9s.js:1:4821)
    at zt (https://app.exemplo/_app/immutable/chunks/B7xq1p.js:1:912)`;

	const MIN_A_OUTRA_COLUNA = `TypeError: undefined is not an object
    at Ki (https://app.exemplo/_app/immutable/chunks/D3kf9s.js:1:5104)
    at zt (https://app.exemplo/_app/immutable/chunks/B7xq1p.js:1:998)`;

	const MIN_B = `TypeError: undefined is not an object
    at Qq (https://app.exemplo/_app/immutable/chunks/ZZZZZZ.js:1:4821)`;

	it('agrupa pela sequência de arquivos, ignorando linha e coluna', () => {
		expect(fingerprint('window', 'x', MIN_A)).toBe(fingerprint('window', 'x', MIN_A_OUTRA_COLUNA));
	});

	it('arquivos diferentes → fingerprints diferentes', () => {
		expect(fingerprint('window', 'x', MIN_A)).not.toBe(fingerprint('window', 'x', MIN_B));
	});
});

describe('fingerprint — camada 3: sem stack', () => {
	// Erro de rede e assertion chegam sem stack. Agrupa por mensagem canônica.
	it('agrupa mensagens que só diferem em número/id', () => {
		expect(fingerprint('promise', 'Falha ao carregar paciente 019fab79-6a3d-77f1-8877-f55dab684566')).toBe(
			fingerprint('promise', 'Falha ao carregar paciente 019fab68-3032-77cb-9618-0824a7327765')
		);
	});

	it('mensagens genuinamente diferentes não agrupam', () => {
		expect(fingerprint('promise', 'Falha ao carregar')).not.toBe(
			fingerprint('promise', 'Timeout na conexão')
		);
	});

	it('a origem separa: o mesmo texto vindo de caminhos diferentes é outro problema', () => {
		expect(fingerprint('promise', 'x')).not.toBe(fingerprint('window', 'x'));
	});
});

describe('fingerprint — forma e estabilidade', () => {
	it('é curto, estável e seguro para rótulo/consulta', () => {
		const f = fingerprint('kit', 'erro', STACK_APP);
		expect(f).toMatch(/^[a-z0-9]{6,16}$/);
		expect(fingerprint('kit', 'erro', STACK_APP)).toBe(f);
	});

	// Determinismo entre cliente e servidor é o requisito que faz o desenho funcionar: o browser
	// usa o fingerprint para deduplicar antes de enviar, e o servidor o RECOMPUTA do zero. Se as
	// duas contas divergissem, a dedução do cliente e o agrupamento do painel contariam coisas
	// diferentes — sem ninguém perceber, porque os dois parecem certos isoladamente.
	it('não depende de nada do ambiente (mesma entrada, mesma saída)', () => {
		const entradas: Array<[string, string, string?]> = [
			['kit', 'erro', STACK_APP],
			['window', 'outro', undefined],
			['promise', '', '']
		];
		for (const [o, m, s] of entradas) {
			expect(fingerprint(o, m, s)).toBe(fingerprint(o, m, s));
		}
	});

	it('aguenta entrada degenerada sem levantar', () => {
		expect(() => fingerprint('', '')).not.toThrow();
		expect(() => fingerprint('x', 'y', 'não é um stack')).not.toThrow();
		expect(fingerprint('', '')).toMatch(/^[a-z0-9]+$/);
	});
});

describe('_canonizar (mensagem sem as partes variáveis)', () => {
	it('troca uuid, número e aspas por marcador', () => {
		expect(_canonizar('paciente 019fab79-6a3d-77f1-8877-f55dab684566 não achado')).toBe(
			_canonizar('paciente 019fab68-3032-77cb-9618-0824a7327765 não achado')
		);
		expect(_canonizar('índice 42 fora')).toBe(_canonizar('índice 7 fora'));
		expect(_canonizar('campo "nome" inválido')).toBe(_canonizar('campo "email" inválido'));
	});
});

describe('_frames (parser de stack)', () => {
	it('entende o formato do Chrome', () => {
		const f = _frames('Error: x\n    at foo (https://a/b/c.ts:1:2)');
		expect(f).toEqual([{ fn: 'foo', file: 'https://a/b/c.ts' }]);
	});

	// O Firefox usa `fn@url`, sem o `at` e sem parênteses. Um parser que só entende Chrome
	// devolveria zero frames e jogaria todo erro de Firefox na camada 3 — agrupando por mensagem
	// erros que são de lugares diferentes, e só para uma fatia dos usuários.
	it('entende o formato do Firefox', () => {
		const f = _frames('foo@https://a/b/c.ts:1:2');
		expect(f).toEqual([{ fn: 'foo', file: 'https://a/b/c.ts' }]);
	});

	it('devolve vazio para texto que não é stack', () => {
		expect(_frames('só uma mensagem')).toEqual([]);
		expect(_frames(undefined)).toEqual([]);
	});
});
