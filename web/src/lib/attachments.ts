// Os anexos do paciente (doc 51), lado do cliente. Só tipos e funções puras — o que fala com a
// API mora em `$lib/server/attachments.ts`, e o que fala com o R2 é o `PUT` do componente.

/** Papéis com acesso a anexo. Espelha `Api.Records.Attachment.papeis/0` — a API é a autoridade. */
export const PAPEIS_ANEXO = ['owner', 'admin', 'recepcao'] as const;

/**
 * Este papel mexe com anexos?
 *
 * A tela esconde a seção inteira para quem não pode, em vez de mostrá-la e dar 403 no clique:
 * um `profissional` não precisa saber que existe um cartão de anexos que ele não abre.
 * A policy do recurso continua sendo quem barra de verdade.
 */
export function canManageAttachments(papel: string | null | undefined): boolean {
	return PAPEIS_ANEXO.includes(papel as (typeof PAPEIS_ANEXO)[number]);
}

export interface Attachment {
	id: string;
	nome: string;
	content_type: string;
	bytes: number;
	status: 'pendente' | 'disponivel';
	inserted_at: string;
}

/** Tetos e allowlist — vêm do SERVIDOR (`limites` do GET), não repetidos aqui. Ver doc 51 §D-3. */
export interface AttachmentLimits {
	max_bytes: number;
	max_por_paciente: number;
	tipos: string[];
}

/** O que o `POST` devolve para o browser conseguir subir direto ao bucket. */
export interface UploadTicket {
	url: string;
	headers: Record<string, string>;
	expira_em: number;
}

/**
 * Tamanho legível. Espelha o `fmtBytes` do protótipo ([`:953`]), com uma diferença: lá o
 * resultado era decorativo (nada impunha teto); aqui o mesmo número aparece ao lado de um limite
 * que o servidor aplica.
 */
export function fmtBytes(b: number): string {
	if (b < 1024) return `${b} B`;
	if (b < 1048576) return `${Math.round(b / 1024)} KB`;
	return `${(b / 1048576).toFixed(1)} MB`;
}

/** É imagem? Decide o ícone da lista (o protótipo mostrava miniatura — ver doc 51 §5.3). */
export function isImagem(contentType: string): boolean {
	return contentType.startsWith('image/');
}

/** Rótulo curto do tipo, para a linha da lista: "PDF", "PNG", "JPEG", "WEBP". */
export function rotuloTipo(contentType: string): string {
	const sub = contentType.split('/')[1] ?? '';
	return sub === 'jpeg' ? 'JPEG' : sub.toUpperCase();
}

/** `2026-07-27T…` → `27/07/2026`. */
export function fmtData(iso: string): string {
	return iso.slice(0, 10).split('-').reverse().join('/');
}

/**
 * O `accept` do `<input type="file">`, montado a partir da allowlist do servidor.
 *
 * O protótipo usava `image/*` ([`:973`]), que inclui **SVG** — e SVG é XML com `<script>`. A
 * lista fechada da API não deixa passar, mas o seletor de arquivos também não deve oferecer:
 * escolher um arquivo e só depois receber 422 é fricção à toa.
 */
export function acceptAttr(tipos: string[]): string {
	return tipos.join(',');
}
