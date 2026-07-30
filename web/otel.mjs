/**
 * Instrumentação do BFF (doc 76) — carregada ANTES da aplicação, com `node --import ./otel.mjs`.
 *
 * ## Por que um arquivo separado, e não `hooks.server.ts`
 *
 * Porque instrumentação automática funciona trocando o módulo por baixo de quem o importa: o
 * `http` do Node e o `undici` (o `fetch` global) só podem ser embrulhados **antes** de o
 * SvelteKit importá-los. Feito de dentro do `hooks.server.ts` — que já roda depois — o SDK sobe,
 * relata sucesso e não intercepta nada. É a pior falha possível: tudo parece ligado e nenhum span
 * aparece.
 *
 * ## O que ele faz de fato
 *
 *   * `http` abre o span de SERVIDOR de cada requisição que chega do browser;
 *   * `undici` abre o span de CLIENTE de cada `fetch` para a API — e é ele quem escreve o header
 *     `traceparent` que o `opentelemetry_bandit` lê do outro lado. Sem esta segunda instrumentação
 *     os dois serviços apareceriam como dois traces separados, cada um contando metade da história.
 *
 * ## Desligado por padrão
 *
 * Sem `OTEL_EXPORTER_OTLP_ENDPOINT` o SDK nem é construído: nada é embrulhado e o processo fica
 * idêntico ao que era. É o mesmo contrato do lado Elixir — ligar trace não pode virar
 * pré-requisito para rodar o projeto.
 */

import { register } from 'node:module';
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { UndiciInstrumentation } from '@opentelemetry/instrumentation-undici';

const destino = process.env.OTEL_EXPORTER_OTLP_ENDPOINT;

/**
 * Requisições que NÃO viram span.
 *
 * É a mesma decisão que o doc 62 §2.1 tomou para o log, e pelo mesmo motivo: alto volume, zero
 * informação. Uma navegação carrega dezenas de arquivos de `/_app/immutable/` — se cada um virar
 * um trace, a lista do Tempo passa a ser 95% JavaScript estático e o trace da requisição que
 * interessa fica invisível no meio.
 *
 * Note que isto é corte de RUÍDO (requisição inteira que não interessa), não poda de ATRIBUTO. A
 * poda dos campos que os spans carregam é decisão separada, e mora no `alloy.alloy` — um lugar
 * só, valendo para os dois serviços.
 */
function ruido(req) {
	const url = req.url ?? '';
	return (
		url.startsWith('/_app/') ||
		url.startsWith('/favicon') ||
		url === '/health' ||
		url === '/api/health'
	);
}

if (destino) {
	// ---- A LINHA SEM A QUAL NADA DISTO FUNCIONA ------------------------------------------------
	//
	// A instrumentação automática troca o módulo por baixo de quem o importa. Em CommonJS isso é
	// feito interceptando `require`; em **ESM** é preciso registrar um loader — e este projeto é
	// ESM ponta a ponta (`"type": "module"`, o Vite, o `build/index.js` do adapter-node).
	//
	// Sem `register`, o SDK sobe, relata sucesso, aceita as instrumentações e **não embrulha
	// nada**. Medido aqui: a API mandava traces normalmente e o BFF não produzia um span sequer,
	// com as variáveis de ambiente todas certas e o `otel.mjs` comprovadamente carregado — o
	// diagnóstico só fechou ao ver que `node -e` (contexto CommonJS) instrumentava e o Vite (ESM)
	// não.
	//
	// ## E `include` não é otimização — é o que impede a instrumentação de quebrar o build
	//
	// Sem a lista, o loader intercepta **todo** módulo ESM do processo, e o embrulho não é
	// transparente para código que inspeciona as próprias funções. Medido na sequência: com o
	// hook aberto, o compilador do Svelte passou a estourar `locator is not a function` e toda
	// página virou 500 — o servidor de dev inteiro derrubado pela ferramenta de observabilidade.
	//
	// Só `http`/`https` precisam do loader. O `undici` (o `fetch` global) NÃO entra na lista de
	// propósito: aquela instrumentação escuta `diagnostics_channel` do próprio Node, sem trocar
	// módulo nenhum — incluí-lo aqui não acrescentaria nada e reabriria a superfície.
	register('import-in-the-middle/hook.mjs', import.meta.url, {
		data: { include: ['http', 'https', 'node:http', 'node:https'] }
	});

	const sdk = new NodeSDK({
		// O exportador lê `OTEL_EXPORTER_OTLP_ENDPOINT` sozinho e acrescenta `/v1/traces`. O destino
		// é o Alloy (porta 4318, OTLP/HTTP), nunca o Tempo direto — ver o cabeçalho do alloy.alloy.
		traceExporter: new OTLPTraceExporter(),
		instrumentations: [
			new HttpInstrumentation({ ignoreIncomingRequestHook: ruido }),
			new UndiciInstrumentation()
		]
	});

	sdk.start();

	// Descarrega o lote pendente no encerramento. `once` e SEM `process.exit`: o adapter-node tem
	// o próprio tratador de SIGTERM para drenar as conexões abertas, e sair daqui cortaria o
	// desligamento gracioso do servidor pela metade — trocar uma requisição interrompida por um
	// punhado de spans é péssimo negócio.
	process.once('SIGTERM', () => void sdk.shutdown().catch(() => {}));
}
