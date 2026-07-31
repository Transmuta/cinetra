// O CEP como ESTADO de formulário: consulta, status na tela e autopreenchimento do endereço.
//
// O `cep.ts` ao lado é a consulta pura (fetch → status + endereço). Isto aqui é a máquina em
// volta dela, que estava escrita duas vezes — **byte a byte, a menos do nome de uma variável
// local** (`d` num arquivo, `digits` no outro) — no `PatientForm` e no `ProfessionalForm`
// (doc 94 §D-1).
//
// A guarda de requisição obsoleta é a parte que não pode se perder numa reescrita: quem digita
// um CEP e corrige o último dígito dispara duas consultas, e a primeira pode responder DEPOIS da
// segunda. Sem comparar `cepReq` com o dígito que voltou, a resposta velha sobrescreve o endereço
// certo — e o campo passa a mostrar a rua de um CEP que a pessoa já corrigiu.

import { lookupCep, type CepStatus } from './cep';
import { maskCep } from './masks';

/** Os campos que o preenchimento automático escreve. */
export interface CamposDeEndereco {
	cep: string;
	endereco: string;
	bairro: string;
	cidade: string;
	uf: string;
}

export function criarCep(f: CamposDeEndereco) {
	let status = $state<CepStatus>(null);
	/** O último CEP consultado. Não é `$state`: só arbitra a corrida, não alimenta a UI. */
	let pedido = '';

	async function consultar(cep: string) {
		const digitos = cep.replace(/\D/g, '');
		if (digitos.length !== 8) {
			status = null;
			return;
		}

		pedido = digitos;
		status = 'loading';

		const { status: resultado, address } = await lookupCep(digitos);

		// Um CEP novo foi digitado durante a consulta: esta resposta já não vale.
		if (pedido !== digitos) return;

		status = resultado;
		if (resultado === 'ok' && address) {
			if (address.endereco) f.endereco = address.endereco;
			if (address.bairro) f.bairro = address.bairro;
			if (address.cidade) f.cidade = address.cidade;
			if (address.uf) f.uf = address.uf;
		}
	}

	return {
		get status() {
			return status;
		},
		/** `oninput` do campo: mascara e dispara a consulta. */
		aoDigitar(e: Event & { currentTarget: HTMLInputElement }) {
			f.cep = maskCep(e.currentTarget.value);
			void consultar(f.cep);
		},
		consultar
	};
}
