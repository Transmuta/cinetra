/**
 * Tira os `.map` de dentro do diretório público, depois do build.
 *
 * ## Por que é necessário, se o sourcemap é `'hidden'`
 *
 * `build.sourcemap: 'hidden'` (vite.config.ts) faz só **uma** coisa: omite o comentário
 * `//# sourceMappingURL` do bundle, para o browser não buscar o mapa sozinho. Ele **não** impede
 * que o `.map` seja escrito na saída — e a saída do adapter-node é `build/client`, que é
 * exatamente o que o sirv serve.
 *
 * Medido ao ligar a opção: 83 arquivos `.map` foram parar em
 * `build/client/_app/immutable/chunks/`, ao lado dos `.js` correspondentes. Como o nome do `.js`
 * é público (está no HTML da página), `<nome>.js.map` é adivinhável em uma tentativa — e com ele
 * sai o código-fonte inteiro da aplicação.
 *
 * "Não referenciado" não é o mesmo que "não acessível". Essa distinção é a razão deste arquivo.
 *
 * ## O que ele faz
 *
 * Move os `.map` de `build/client` para `sourcemaps/`, preservando o caminho relativo — de onde
 * eles servem para traduzir um stack de produção na investigação, sem estarem ao alcance de
 * qualquer visitante. `sourcemaps/` fica fora do que é servido e fora do git.
 *
 * ## O limite desta verificação, medido
 *
 * A conferência do fim (relê o diretório e falha se sobrou `.map`) é **fraca de propósito
 * declarado**: como o laço acima move tudo o que encontra, ela quase nunca pode falhar. Testado —
 * plantar um `.map` no público e rodar o script faz ele ser *movido*, não denunciado.
 *
 * Ela serve para o caso estreito de um `rename` que falhe sem levantar. **O risco real é outro: o
 * script não rodar.** Trocar `npm run build` por `vite build`, ou tirar o `postbuild` do
 * package.json, desliga a proteção sem sintoma nenhum — e nenhum código dentro deste arquivo pode
 * detectar isso.
 *
 * Por isso a guarda que vale está no [`Dockerfile.prod`](../Dockerfile.prod), que confere
 * `build/client` **depois** do build e falha a imagem. É onde a checagem pode falhar de forma
 * independente de quem deveria tê-la executado.
 */

import { existsSync } from 'node:fs';
import { mkdir, readdir, rename } from 'node:fs/promises';
import { dirname, join, relative } from 'node:path';

const PUBLICO = 'build/client';
const DESTINO = 'sourcemaps';

/** Todos os arquivos sob `dir`, recursivamente. */
async function arquivos(dir) {
	const saida = [];
	for (const entrada of await readdir(dir, { withFileTypes: true })) {
		const caminho = join(dir, entrada.name);
		if (entrada.isDirectory()) saida.push(...(await arquivos(caminho)));
		else saida.push(caminho);
	}
	return saida;
}

if (!existsSync(PUBLICO)) {
	// Não é erro: `npm run build` pode não ter rodado ainda, ou o adapter pode ter mudado de saída.
	// Avisar é melhor que falhar, porque este script também roda em contexto de desenvolvimento.
	console.warn(`[sourcemaps] ${PUBLICO} não existe — nada a mover.`);
	process.exit(0);
}

const mapas = (await arquivos(PUBLICO)).filter((f) => f.endsWith('.map'));

for (const mapa of mapas) {
	const alvo = join(DESTINO, relative(PUBLICO, mapa));
	await mkdir(dirname(alvo), { recursive: true });
	await rename(mapa, alvo);
}

// A conferência. Não confia no laço acima: relê o diretório do zero.
const sobraram = (await arquivos(PUBLICO)).filter((f) => f.endsWith('.map'));
if (sobraram.length > 0) {
	console.error(
		`[sourcemaps] ${sobraram.length} arquivo(s) .map continuam no diretório público:\n` +
			sobraram.map((f) => `  ${f}`).join('\n') +
			`\nIsso expõe o código-fonte. O build foi interrompido de propósito.`
	);
	process.exit(1);
}

console.log(`[sourcemaps] ${mapas.length} mapa(s) movidos para ${DESTINO}/ — nenhum no público.`);
