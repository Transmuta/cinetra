// CPF clássico: 9 dígitos + 2 verificadores por módulo 11 — irmão do `cnpj.ts`, espelho de
// `Api.Cpf` (AN-11 / HOM-012, D10 "barra no salvar"). A autoridade é o servidor; aqui a régua
// só chega antes da viagem, para o 422 não ser a primeira notícia.

/** Verdadeiro se o valor (com ou sem máscara) tem 11 dígitos e os dois DVs conferem. */
export function isValidCpf(value: string): boolean {
	const digits = value.replace(/\D/g, '');
	if (digits.length !== 11) return false;
	// Sequência de um dígito só fecha a conta, mas não é um CPF emitido.
	if (/^(\d)\1{10}$/.test(digits)) return false;

	const nums = [...digits].map(Number);
	return (
		nums[9] === checkDigit(nums.slice(0, 9), 10) && nums[10] === checkDigit(nums.slice(0, 10), 11)
	);
}

// Σ (dígito × peso decrescente) → `soma × 10 mod 11`, com 10 ≡ 0 (a forma fechada da Receita).
function checkDigit(nums: number[], pesoInicial: number): number {
	const soma = nums.reduce((acc, d, i) => acc + d * (pesoInicial - i), 0);
	const dv = (soma * 10) % 11;
	return dv === 10 ? 0 : dv;
}
