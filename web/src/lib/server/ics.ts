// O evento de calendário que a tela de confirmação oferece ao paciente ("adicionar à agenda").
//
// Mora em `lib/server/` por duas razões: o `uidDeSessao` usa `node:crypto`, e o arquivo só é
// montado por um route handler — nada disso precisa viajar para o browser.
//
// ## Por que um arquivo, e não um link de "adicionar ao Google Agenda"
//
// Porque metade dos pacientes não usa Google Agenda, e um link para um serviço específico manda
// quem usa iPhone para uma tela de login que não resolve nada. Um `.ics` servido pelo nosso
// domínio é aberto pelo app de calendário **padrão** do aparelho, seja ele qual for — e não conta
// a ninguém de fora que essa pessoa tem sessão nesta clínica.
//
// ## O que o RFC 5545 cobra, e o que acontece quando não se paga
//
// O leitor do outro lado é o app do celular, e ele não perdoa: linha terminada em LF sozinho,
// vírgula não escapada ou linha acima de 75 octetos produzem "não foi possível abrir" sem dizer
// onde. Cada regra abaixo existe por causa de um desses.

import { createHash } from 'node:crypto';
import { utcCompacto } from '$lib/calendario';

export interface EventoIcs {
	uid: string;
	/** Instante ISO (UTC) do começo. */
	inicio: string;
	/** Instante ISO (UTC) do fim. */
	fim: string;
	titulo: string;
	descricao?: string;
	local?: string;
	/** Instante ISO (UTC) do `DTSTAMP` — parâmetro, e não `new Date()`, para o teste ser estável. */
	agora: string;
}

/**
 * Identificador do evento no calendário de quem baixa.
 *
 * Estável por link: remarcada a sessão, o mesmo `UID` faz o app **atualizar** o evento em vez de
 * criar um segundo — que é o defeito clássico de `.ics` gerado com id aleatório.
 *
 * É um digest, e não o token: o arquivo pode acabar num calendário compartilhado com a família, e
 * o token é o que responde pela pessoa. Dezesseis hexadígitos (64 bits) bastam para não colidir
 * dentro de um calendário e não têm volta para o token.
 */
export function uidDeSessao(token: string): string {
	return `${createHash('sha256').update(token).digest('hex').slice(0, 16)}@cinetra`;
}

/**
 * Escapa o que é texto livre. Nome de clínica é digitado no balcão, e "Reabilitar, Corpo &
 * Movimento" já basta para produzir um arquivo inválido — a vírgula separa valores no formato.
 */
function escapar(texto: string): string {
	return texto
		.replace(/\\/g, '\\\\')
		.replace(/;/g, '\\;')
		.replace(/,/g, '\\,')
		.replace(/\r?\n/g, '\\n');
}

/**
 * Dobra a linha em 75 **octetos**, continuando com um espaço.
 *
 * O limite do RFC é em bytes, não em caracteres — "sessão" ocupa 7 bytes em 6 letras —, e o corte
 * não pode cair no meio de um caractere multibyte: partir o "ç" ao meio produz um arquivo que o
 * app abre como lixo. Por isso a conta é feita byte a byte, avançando de caractere em caractere.
 */
function dobrar(linha: string): string {
	const bytes = (s: string) => new TextEncoder().encode(s).length;
	if (bytes(linha) <= 75) return linha;

	const partes: string[] = [];
	let atual = '';
	// O `[...linha]` itera por ponto de código (e não por unidade UTF-16), para emoji e acento
	// composto continuarem inteiros.
	for (const ch of [...linha]) {
		// A partir da segunda linha, o espaço de continuação consome um dos 75.
		const teto = partes.length === 0 ? 75 : 74;
		if (bytes(atual + ch) > teto) {
			partes.push(atual);
			atual = '';
		}
		atual += ch;
	}
	partes.push(atual);

	return partes.map((p, i) => (i === 0 ? p : ` ${p}`)).join('\r\n');
}

/** O `.ics` de uma sessão: um VEVENT, sem alarme e sem fuso declarado. */
export function eventoIcs(evento: EventoIcs): string {
	const campos: string[] = [
		'BEGIN:VCALENDAR',
		'VERSION:2.0',
		// Identifica quem gerou; alguns clientes o exigem para não recusar o arquivo.
		'PRODID:-//Cinetra//Agenda de sessoes//PT-BR',
		'CALSCALE:GREGORIAN',
		'METHOD:PUBLISH',
		'BEGIN:VEVENT',
		`UID:${evento.uid}`,
		`DTSTAMP:${utcCompacto(evento.agora)}`,
		`DTSTART:${utcCompacto(evento.inicio)}`,
		`DTEND:${utcCompacto(evento.fim)}`,
		`SUMMARY:${escapar(evento.titulo)}`
	];

	// Campo vazio não é o mesmo que campo ausente: `DESCRIPTION:` sem valor faz alguns clientes
	// mostrarem uma linha em branco no evento.
	if (evento.descricao) campos.push(`DESCRIPTION:${escapar(evento.descricao)}`);
	if (evento.local) campos.push(`LOCATION:${escapar(evento.local)}`);

	campos.push('END:VEVENT', 'END:VCALENDAR');

	return campos.map(dobrar).join('\r\n');
}
