// O endereço estruturado, como TEXTO.
//
// Paciente, profissional e clínica guardam os mesmos sete campos, com os mesmos nomes de
// propósito (ver o comentário do `Api.Accounts.Clinic`) — e por isso a leitura deles cabe num
// módulo só, do mesmo jeito que a ESCRITA já cabe num `AddressFields.svelte` só.
//
// A regra inteira daqui é uma: **o campo vazio some, e o separador dele vai junto**. Escrita à
// mão, ela vira "— , — - SP" na primeira clínica que só preencheu a cidade; escrita à mão em
// cada tela, ela vira sete versões diferentes de quando pôr vírgula.

import { maskCep } from './masks';

export interface Endereco {
	cep?: string | null;
	/** O logradouro (só a rua) — o nome é histórico: já foi a linha livre inteira. */
	endereco?: string | null;
	numero?: string | null;
	complemento?: string | null;
	bairro?: string | null;
	cidade?: string | null;
	uf?: string | null;
}

function preenchido(v: string | null | undefined): v is string {
	return typeof v === 'string' && v.trim() !== '';
}

function juntar(partes: (string | null | undefined)[], sep: string): string {
	return partes
		.filter(preenchido)
		.map((p) => p.trim())
		.join(sep);
}

/** O lugar: "Av. Paulista, 1000". */
export function logradouroCompleto(e: Endereco): string {
	return juntar([e.endereco, e.numero], ', ');
}

/** A localidade: "Bela Vista · São Paulo/SP · CEP 01310-100". */
export function localidade(e: Endereco): string {
	// O CEP sai rotulado porque sozinho numa linha ele lê como número de protocolo — e
	// mascarado porque o formulário guarda o que a pessoa digitou, mas quem escreve pela API
	// pode mandar os oito dígitos crus.
	const cep = preenchido(e.cep) ? `CEP ${maskCep(e.cep)}` : null;
	return juntar([e.bairro, juntar([e.cidade, e.uf], '/'), cep], ' · ');
}

/**
 * O endereço em até três linhas — o lugar, o complemento e a localidade.
 *
 * Três, e não uma por campo: no sidebar isto vive numa coluna de 256px em corpo `text-rotulo`,
 * e sete linhas fariam a identidade da clínica ficar mais alta que a própria navegação. Linha
 * vazia não entra.
 *
 * O complemento ganhou linha própria depois de medido no browser: colado ao logradouro por
 * " — ", um endereço real ("Avenida Brigadeiro Faria Lima, 3477 — Torre Sul, Conj. 1401")
 * quebra na coluna estreita e o travessão **abre** a linha de baixo, o que lê como erro de
 * renderização. Cada linha aqui é uma unidade inteira: nenhuma pode começar por separador.
 */
export function linhasDeEndereco(e: Endereco): string[] {
	return [logradouroCompleto(e), e.complemento ?? '', localidade(e)]
		.map((linha) => linha.trim())
		.filter((linha) => linha !== '');
}

/**
 * As mesmas linhas numa só, para quem lê o endereço dentro de uma `<dd>`. Vazio é `''` — quem
 * desenha a tela decide como dizer "não tem".
 */
export function enderecoEmLinha(e: Endereco): string {
	return linhasDeEndereco(e).join(' · ');
}
