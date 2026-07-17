// CNPJ **alfanumérico** (Receita Federal / Serpro, vigente a partir de jul/2026): 12 posições
// alfanuméricas + 2 dígitos verificadores numéricos, validados por módulo 11 com o valor de
// cada caractere = `código ASCII − 48` (`'0'..'9' → 0..9`, `'A' → 17`, …). Espelho client de
// `Api.Cnpj`: a autoridade é a API — isto só formata o input e dá feedback antes do round-trip.

const WEIGHTS_FIRST = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
const WEIGHTS_SECOND = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];

// Forma canônica de armazenamento: só [0-9A-Z], em maiúsculas, sem máscara.
export function normalizeCnpj(value: string): string {
	return value.toUpperCase().replace(/[^0-9A-Z]/g, '');
}

// Insere a máscara `XX.XXX.XXX/XXXX-XX` progressivamente, formatando também entradas parciais
// enquanto se digita. Trunca em 14 posições.
export function maskCnpj(value: string): string {
	const s = normalizeCnpj(value).slice(0, 14);
	let out = s.slice(0, 2);
	if (s.length > 2) out += '.' + s.slice(2, 5);
	if (s.length > 5) out += '.' + s.slice(5, 8);
	if (s.length > 8) out += '/' + s.slice(8, 12);
	if (s.length > 12) out += '-' + s.slice(12, 14);
	return out;
}

// Verdadeiro se, normalizado, tem 14 posições e os dois DV conferem. Rejeita `00000000000000`.
export function isValidCnpj(value: string): boolean {
	const s = normalizeCnpj(value);
	if (s.length !== 14 || s === '00000000000000') return false;
	const d1 = checkDigit(s.slice(0, 12), WEIGHTS_FIRST);
	const d2 = checkDigit(s.slice(0, 12) + d1, WEIGHTS_SECOND);
	return s[12] === d1 && s[13] === d2;
}

function checkDigit(chars: string, weights: number[]): string {
	let sum = 0;
	for (let i = 0; i < chars.length; i++) sum += (chars.charCodeAt(i) - 48) * weights[i];
	const remainder = sum % 11;
	return String(remainder < 2 ? 0 : 11 - remainder);
}
