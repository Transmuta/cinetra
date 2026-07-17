// Máscaras de input progressivas — formatam enquanto se digita, espelho dos helpers do
// protótipo (`maskCPF`/`maskTel`/`maskCEP`, :1958). Puras e testáveis; a validação real é do
// backend (a máscara é só UX). O CNPJ mora em `$lib/cnpj` (alfanumérico, Serpro).

const onlyDigits = (v: string): string => (v ?? '').replace(/\D/g, '');

// 000.000.000-00
export function maskCpf(value: string): string {
	const d = onlyDigits(value).slice(0, 11);
	let o = d.slice(0, 3);
	if (d.length > 3) o += '.' + d.slice(3, 6);
	if (d.length > 6) o += '.' + d.slice(6, 9);
	if (d.length > 9) o += '-' + d.slice(9, 11);
	return o;
}

// (11) 90000-0000 — cobre fixo (10 dígitos) e celular (11).
export function maskTel(value: string): string {
	const d = onlyDigits(value).slice(0, 11);
	if (d.length === 0) return '';
	if (d.length <= 2) return '(' + d;
	let o = '(' + d.slice(0, 2) + ') ';
	const r = d.slice(2);
	if (r.length <= 4) return o + r;
	if (d.length <= 10) o += r.slice(0, 4) + '-' + r.slice(4);
	else o += r.slice(0, 5) + '-' + r.slice(5);
	return o;
}

// 00000-000
export function maskCep(value: string): string {
	const d = onlyDigits(value).slice(0, 8);
	return d.length > 5 ? d.slice(0, 5) + '-' + d.slice(5) : d;
}

// Ano de 4 dígitos (AAAA) — só dígitos, truncado.
export function maskAno(value: string): string {
	return onlyDigits(value).slice(0, 4);
}

// UF: até 2 letras, maiúsculas (o `class="uppercase"` é só visual; o valor guardado também
// precisa subir a caixa).
export function maskUf(value: string): string {
	return (value ?? '').replace(/[^a-zA-Z]/g, '').toUpperCase().slice(0, 2);
}
