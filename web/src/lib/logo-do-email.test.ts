import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { inflateSync } from 'node:zlib';

// O logo que o `Api.EmailLayout` serve por URL (`/email/logo-cinetra.png`). Ele mora aqui, no
// `web`, e é consumido lá, no `api` — ninguém que regenerar a arte vai rodar a suíte do backend.
//
// Ele já foi um PNG **sem canal alfa**, com a cor da faixa (#212A37) achatada dentro da própria
// imagem. O efeito só aparecia em caixa com tema escuro: cliente que repinta o e-mail por conta
// própria clareava a faixa do cabeçalho e deixava a imagem intacta, e a placa embutida virava um
// retângulo escuro solto por cima. Com fundo transparente, a faixa é a `<td>` — e o que estiver
// atrás dela é o que aparece.
const CAMINHO = resolve(__dirname, '../../static/email/logo-cinetra.png');

// O PNG desmontado à mão: não vale a pena uma dependência para ler um cabeçalho de 25 bytes e
// desfazer cinco filtros de linha. Devolve largura, altura e os pixels RGBA.
function lerPng(bytes: Buffer) {
	expect(bytes.subarray(0, 8)).toEqual(
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
	);

	let pos = 8;
	let ihdr: Buffer | undefined;
	const idat: Buffer[] = [];

	while (pos < bytes.length) {
		const tamanho = bytes.readUInt32BE(pos);
		const tipo = bytes.toString('ascii', pos + 4, pos + 8);
		const dados = bytes.subarray(pos + 8, pos + 8 + tamanho);
		if (tipo === 'IHDR') ihdr = dados;
		if (tipo === 'IDAT') idat.push(dados);
		pos += 12 + tamanho;
	}

	if (!ihdr) throw new Error('PNG sem IHDR');

	const largura = ihdr.readUInt32BE(0);
	const altura = ihdr.readUInt32BE(4);
	const profundidade = ihdr.readUInt8(8);
	const tipoDeCor = ihdr.readUInt8(9);
	const entrelacado = ihdr.readUInt8(12);

	return { largura, altura, profundidade, tipoDeCor, entrelacado, idat };
}

// Desfaz os filtros por linha (PNG §9.2). Só o caso que a arte usa: 8 bits, RGBA, sem entrelace.
function pixels(png: ReturnType<typeof lerPng>) {
	if (png.tipoDeCor !== 6) {
		throw new Error(`o PNG não é RGBA (tipo de cor ${png.tipoDeCor}) — regenere com fundo vazado`);
	}

	const bpp = 4;
	const cru = inflateSync(Buffer.concat(png.idat));
	const largura = png.largura * bpp;
	const saida = Buffer.alloc(png.altura * largura);

	for (let y = 0; y < png.altura; y++) {
		const filtro = cru[y * (largura + 1)];
		const linha = cru.subarray(y * (largura + 1) + 1, (y + 1) * (largura + 1));

		for (let x = 0; x < largura; x++) {
			const a = x >= bpp ? saida[y * largura + x - bpp] : 0;
			const b = y > 0 ? saida[(y - 1) * largura + x] : 0;
			const c = x >= bpp && y > 0 ? saida[(y - 1) * largura + x - bpp] : 0;
			let valor: number;

			switch (filtro) {
				case 0:
					valor = linha[x];
					break;
				case 1:
					valor = linha[x] + a;
					break;
				case 2:
					valor = linha[x] + b;
					break;
				case 3:
					valor = linha[x] + ((a + b) >> 1);
					break;
				case 4: {
					const p = a + b - c;
					const pa = Math.abs(p - a);
					const pb = Math.abs(p - b);
					const pc = Math.abs(p - c);
					valor = linha[x] + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
					break;
				}
				default:
					throw new Error(`filtro PNG desconhecido: ${filtro}`);
			}

			saida[y * largura + x] = valor & 0xff;
		}
	}

	return saida;
}

describe('o logo servido aos e-mails', () => {
	const png = lerPng(readFileSync(CAMINHO));

	it('tem canal alfa — sem ele a cor da faixa vem achatada dentro da arte', () => {
		expect(png.tipoDeCor).toBe(6);
		expect(png.profundidade).toBe(8);
		expect(png.entrelacado).toBe(0);
	});

	it('os quatro cantos são transparentes, e não a cor do cabeçalho', () => {
		// O canal alfa existir não basta: um PNG RGBA com a placa pintada e alfa 255 em tudo
		// produziria exatamente o mesmo retângulo. O que precisa valer é o fundo ser vazado.
		const rgba = pixels(png);
		const alfa = (x: number, y: number) => rgba[(y * png.largura + x) * 4 + 3];

		for (const [x, y] of [
			[0, 0],
			[png.largura - 1, 0],
			[0, png.altura - 1],
			[png.largura - 1, png.altura - 1],
		]) {
			expect(alfa(x, y), `canto (${x},${y}) opaco`).toBe(0);
		}
	});

	it('mantém as medidas que o `<img>` do e-mail declara (150x44 em 2x)', () => {
		// `width`/`height` no `<img>` não são decoração: sem eles o layout pula quando a imagem
		// finalmente carrega. Se a arte mudar de proporção, o atributo lá tem de mudar junto.
		expect(png.largura).toBe(318);
		expect(png.altura).toBe(94);
	});
});
