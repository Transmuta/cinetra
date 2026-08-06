// Monta `src/lib/ajuda/prints.json` a partir do que existe em `static/ajuda/` (doc 108 §4).
//
// O manifesto é uma FUNÇÃO PURA da pasta, e é isso que resolve o problema que ele existe para
// resolver. A alternativa natural — cada spec do Playwright anotar a própria captura num arquivo
// compartilhado — teria dois defeitos: escrita concorrente entre workers e, pior, um manifesto que
// só conhece as prints tiradas NAQUELA execução. Regenerar uma seção só apagaria o resto.
//
// A dimensão sai do cabeçalho do PNG, não de uma biblioteca: um IHDR tem largura e altura em dois
// inteiros de 32 bits em posição fixa (bytes 16..24). Ler 24 bytes evita uma dependência inteira
// para responder a pergunta mais simples que existe sobre uma imagem.

import { readdirSync, statSync, openSync, readSync, closeSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PASTA = resolve(raiz, 'static/ajuda');
const DESTINO = resolve(raiz, 'src/lib/ajuda/prints.json');

const ASSINATURA_PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Largura e altura de um PNG, lidas do IHDR. Levanta se o arquivo não for PNG. */
function dimensoes(caminho) {
	const cabecalho = Buffer.alloc(24);
	const fd = openSync(caminho, 'r');
	try {
		readSync(fd, cabecalho, 0, 24, 0);
	} finally {
		closeSync(fd);
	}

	if (!cabecalho.subarray(0, 8).equals(ASSINATURA_PNG)) {
		throw new Error(`${caminho} não é um PNG — o gerador só produz PNG.`);
	}
	return { largura: cabecalho.readUInt32BE(16), altura: cabecalho.readUInt32BE(20) };
}

let arquivos = [];
try {
	arquivos = readdirSync(PASTA).filter((f) => f.endsWith('.png')).sort();
} catch {
	console.error(`Nada em ${PASTA} — rode as capturas antes: npm run prints:capturar`);
}

const prints = {};
for (const arquivo of arquivos) {
	const id = arquivo.replace(/\.png$/, '');
	prints[id] = { arquivo, ...dimensoes(resolve(PASTA, arquivo)) };
}

// A data vem do arquivo mais novo da pasta, e não de `new Date()`: assim, rodar o script duas
// vezes sem capturar nada não produz diff — e o `git diff` do manifesto passa a significar
// "alguma print mudou", que é o único significado útil que ele pode ter.
const maisNovo = arquivos.reduce(
	(max, arquivo) => Math.max(max, statSync(resolve(PASTA, arquivo)).mtimeMs),
	0
);

writeFileSync(
	DESTINO,
	`${JSON.stringify(
		{
			gerado_em: maisNovo ? new Date(maisNovo).toISOString().slice(0, 10) : '',
			prints
		},
		null,
		2
	)}\n`
);

console.log(`manifesto: ${arquivos.length} prints → ${DESTINO}`);
