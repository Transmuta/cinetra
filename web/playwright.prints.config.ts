import { defineConfig, devices } from '@playwright/test';
import { API_ORIGIN } from './e2e/env';

/**
 * As prints da central de ajuda (doc 108 §4).
 *
 * Config separada da e2e, e não um `project` dela, porque os dois alvos querem coisas opostas:
 * a e2e quer o `build` + `preview` (a configuração de produção, com a CSP assada) e falha quando
 * a asserção não bate; este quer a stack de DESENVOLVIMENTO já de pé e um viewport fixo, e o
 * "resultado" dele não é um veredito — é um diretório de arquivos.
 *
 * ## Por que não sobe servidor
 *
 * Um `webServer` faria `build` + `preview` a cada regeneração de print, e regeneração de print é
 * coisa que se faz depois de mexer numa tela — no meio do trabalho, várias vezes. O alvo é o `vite
 * dev` que já está no ar no compose. Se ele não estiver, os specs falham na primeira navegação com
 * o endereço na mensagem, que é diagnóstico suficiente.
 *
 * ## O viewport é parte do contrato
 *
 * 1440×900 em escala 1. Escala 2 daria imagem mais nítida em tela retina e **quadruplicaria** o
 * peso de ~70 arquivos numa página que é lida no celular da recepção — a nitidez não paga o
 * segundo de carregamento. O celular tem projeto próprio, abaixo.
 */
const baseURL = process.env.PRINTS_BASE_URL || 'http://localhost:5173';

export default defineConfig({
	testDir: 'e2e/prints',
	testMatch: /.*\.prints\.ts/,
	// Sequencial de propósito: o gargalo aqui não é CPU, é o banco de dev — e print é trabalho de
	// bastidor, não gate de CI. Rodar em série também deixa a saída legível quando uma falha.
	workers: 1,
	// Duas repetições. Não é para esconder spec quebrado — falha determinística repete e continua
	// vermelha. É para a PRIMEIRA navegação a uma rota do `vite dev`, que ainda está compilando:
	// o clique chega antes da hidratação e o envio faz o round-trip inteiro, estourando os 10s do
	// `expect`. Medido nesta leva, e só nesta configuração (a e2e roda contra o build).
	retries: 2,
	timeout: 120_000,
	expect: { timeout: 10_000 },
	reporter: 'list',
	use: {
		baseURL,
		...devices['Desktop Chrome'],
		viewport: { width: 1440, height: 900 },
		deviceScaleFactor: 1,
		// A central é servida no tema claro do produto (a casca dela usa os tokens do app, e o
		// tópico do tema mostra o escuro à parte). Fixar aqui impede que a preferência da máquina
		// de quem regenera troque metade das imagens sem ninguém pedir.
		colorScheme: 'light',
		locale: 'pt-BR',
		timezoneId: 'America/Sao_Paulo'
	},
	metadata: { apiOrigin: API_ORIGIN }
});
