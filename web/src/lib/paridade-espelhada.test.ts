import { describe, it, expect } from 'vitest';
import { readFileSync, existsSync } from 'node:fs';
import { isValidCpf } from './cpf';
import { isValidCnpj } from './cnpj';
import { canonizarTelefone } from './telefone';
import { validateDayPeriods, type Period } from './scheduling';

// O lado TypeScript do contrato de paridade — o gêmeo de
// `api/test/api/paridade_espelhada_test.exs`.
//
// Os casos NÃO moram aqui. Vêm de `contratos/regras-espelhadas.json`, na raiz do repositório, e o
// teste Elixir lê o mesmo arquivo. É essa a única propriedade que importa: duas listas de casos,
// ainda que idênticas hoje, divergem no dia em que alguém acrescenta um caso de um lado só — e aí
// os dois testes ficam verdes sobre implementações que discordam.
//
// `docs/04-arquitetura.md §10` já mandava que "onde há espelho, a paridade é garantida por
// contrato de teste compartilhado, nunca por cópia mantida a olho". O contrato não existia: cada
// arquivo trazia um comentário dizendo "espelho de X", e a prosa era a verificação inteira
// (doc 101, A5).
//
// No CI o checkout inteiro está em `../`; no container de dev, onde só `web/` é montado em `/app`,
// o `docker-compose.yml` monta a raiz do repositório em `/repo` só-leitura.
const CAMINHOS = ['../contratos/regras-espelhadas.json', '/repo/contratos/regras-espelhadas.json'];

interface Caso<E, S> {
	entrada: E;
	esperado: S;
	porque: string;
}

interface Secao<E, S> {
	elixir: string;
	typescript: string;
	casos: Caso<E, S>[];
}

// Falha em vez de pular quando o contrato não é alcançável: um teste de contrato que some sozinho
// no ambiente errado reporta verde sem ter olhado nada.
function lerContrato(): Record<string, Secao<unknown, unknown>> {
	const caminho = CAMINHOS.find((c) => existsSync(c));
	if (!caminho) {
		throw new Error(`regras-espelhadas.json não encontrado em nenhum de: ${CAMINHOS.join(', ')}`);
	}
	return JSON.parse(readFileSync(caminho, 'utf-8'));
}

const CONTRATO = lerContrato();

function casos<E, S>(secao: string): Caso<E, S>[] {
	return (CONTRATO[secao] as unknown as Secao<E, S>).casos;
}

// Cada caso vira um teste próprio (`it.each`), e não um laço dentro de um teste: assim o nome do
// caso que quebrou aparece no relatório, com o "porquê" que o contrato registra.
function confere<E, S>(secao: string, fn: (entrada: E) => S) {
	it.each(casos<E, S>(secao))('$entrada → $esperado ($porque)', ({ entrada, esperado }) => {
		expect(fn(entrada)).toEqual(esperado);
	});
}

describe('CPF', () => confere<string, boolean>('cpf', isValidCpf));
describe('CNPJ', () => confere<string, boolean>('cnpj', isValidCnpj));
describe('telefone canônico', () =>
	confere<string, string | null>('telefone_canonico', canonizarTelefone));

// A regra do e-mail mora numa regex repetida no BFF (`sondaEmail`, em
// `routes/api/patients/lookup/+server.ts`), que não a exporta. O contrato prende a REGEX, então é
// ela que se exercita — e o dia em que as duas divergirem, este teste é que avisa.
describe('e-mail (forma mínima)', () =>
	confere<string, boolean>('email_forma_minima', (v) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)));

describe('períodos do dia', () =>
	confere<Period[], boolean>('periodos_do_dia', (p) => validateDayPeriods(p).ok));

// A metassegurança: se o arquivo mudar de forma (uma seção renomeada, um bloco esvaziado), os
// `describe` acima passariam a registrar zero testes e o arquivo reportaria verde. Este cobra a
// forma — e é o gêmeo exato do teste homônimo do lado Elixir.
describe('o contrato', () => {
	it.each(['cpf', 'cnpj', 'telefone_canonico', 'email_forma_minima', 'periodos_do_dia'])(
		'seção %s existe e não está vazia',
		(secao) => {
			expect(CONTRATO[secao], `seção \`${secao}\` sumiu do contrato`).toBeDefined();
			expect(casos(secao).length).toBeGreaterThanOrEqual(5);
		}
	);
});
