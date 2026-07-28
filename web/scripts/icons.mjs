// Gera os ícones de app a partir de `src/lib/assets/favicon.svg` — a MESMA arte do favicon,
// para não existirem duas versões da marca que divergem na próxima troca.
//
// Roda à mão:  node scripts/icons.mjs
//
// Irmão de `og-image.mjs`, e pelo mesmo motivo: o Chromium já vem com o Playwright
// (devDependency), então rasterizar SVG não custa dependência nova. Como o SVG é embutido no
// HTML (não referenciado por `file://`), não há o problema de CORS que mordeu o card OG.
//
// ## As três decisões que o formato impõe
//
// 1. **Fundo opaco, sempre.** O iOS não respeita transparência em `apple-touch-icon`: PNG com
//    alpha ganha fundo PRETO atrás da marca. Como os dois traços são sálvia e azul médio, o
//    papel da marca (#F6F4EF) é o único fundo em que os dois se leem — sobre o navy o traço
//    azul quase some.
//
// 2. **Folga nas bordas.** Tanto o iOS quanto os launchers do Android recortam o quadrado (o
//    "squircle"). Marca encostada na borda é marca cortada.
//
// 3. **`maskable` é outro ícone, não o mesmo.** A área garantida de um ícone maskable é o
//    círculo central de 80% do lado; um quadrado inscrito nesse círculo tem ~56% do lado. Por
//    isso o maskable leva a marca bem menor e o fundo sangrando até a borda — usar o ícone
//    comum como maskable é o que produz aquele logo cortado nos cantos.

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const raiz = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const svg = readFileSync(`${raiz}/src/lib/assets/favicon.svg`, 'utf8')
	// O arquivo traz `width`/`height` fixos (272×265) que venceriam o tamanho do container.
	.replace(/\s(width|height)="[^"]*"/g, '');

const PAPEL = '#F6F4EF';

/** `escala` = fração do lado ocupada pela marca. O resto é folga. */
const ICONES = [
	// 180 é o tamanho que o iOS pede desde o iPhone 6 Plus; um só basta, o sistema reduz.
	{ arquivo: 'apple-touch-icon.png', lado: 180, escala: 0.62 },
	{ arquivo: 'icon-192.png', lado: 192, escala: 0.66 },
	{ arquivo: 'icon-512.png', lado: 512, escala: 0.66 },
	// Ver decisão 3 no topo: a marca cabe no círculo de segurança, não no quadrado.
	{ arquivo: 'icon-maskable-512.png', lado: 512, escala: 0.5 }
];

const navegador = await chromium.launch({ args: ['--no-sandbox'] });

for (const { arquivo, lado, escala } of ICONES) {
	const pagina = await navegador.newPage({ viewport: { width: lado, height: lado } });
	await pagina.setContent(
		`<!doctype html><html><head><meta charset="utf-8"><style>
		   *{margin:0;padding:0}
		   body{width:${lado}px;height:${lado}px;background:${PAPEL};
		        display:grid;place-items:center;overflow:hidden}
		   svg{width:${Math.round(lado * escala)}px;height:auto;display:block}
		 </style></head><body>${svg}</body></html>`,
		{ waitUntil: 'load' }
	);
	await pagina.screenshot({ path: `${raiz}/static/${arquivo}`, omitBackground: false });
	await pagina.close();
	console.log(`${arquivo}  ${lado}×${lado}  marca a ${Math.round(escala * 100)}%`);
}

await navegador.close();

// O manifest sai deste mesmo script para não haver ícone declarado que ninguém gerou (nem o
// contrário): a lista acima é a fonte, e o JSON é derivado dela.
//
// `start_url` é a agenda, não a raiz: quem instalou o app não quer abrir na página de vendas.
// Sem sessão, `/agenda` já redireciona para `/entrar` — a guarda do layout do `(app)` resolve,
// e não é preciso repetir a regra aqui.
const manifest = {
	id: '/',
	name: 'Cinetra',
	short_name: 'Cinetra',
	description: 'Agenda e gestão para clínicas de fisioterapia.',
	lang: 'pt-BR',
	dir: 'ltr',
	start_url: '/agenda',
	scope: '/',
	display: 'standalone',
	background_color: PAPEL,
	// O mesmo navy do `<meta name="theme-color">` da landing.
	theme_color: '#212A37',
	icons: [
		{ src: '/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
		{ src: '/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
		{ src: '/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }
	]
};

writeFileSync(`${raiz}/static/manifest.webmanifest`, `${JSON.stringify(manifest, null, 2)}\n`);
console.log('manifest.webmanifest');
