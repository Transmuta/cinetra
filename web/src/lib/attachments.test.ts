import { describe, it, expect } from 'vitest';
import {
	canManageAttachments,
	fmtBytes,
	fmtData,
	isImagem,
	rotuloTipo,
	acceptAttr,
	PAPEIS_ANEXO
} from './attachments';

describe('canManageAttachments — o recorte de papel dos anexos', () => {
	it('owner, admin e recepção têm acesso', () => {
		for (const papel of ['owner', 'admin', 'recepcao']) {
			expect(canManageAttachments(papel)).toBe(true);
		}
	});

	// A ficha inteira é visível para todo membro (D16); anexo é a ÚNICA exceção, e ela exclui o
	// profissional. Se este teste ficar vermelho, alguém mudou a decisão de produto — e precisa
	// mudar `Api.Records.Attachment.papeis/0` junto.
	it('profissional NÃO tem — é a exceção ao D16', () => {
		expect(canManageAttachments('profissional')).toBe(false);
	});

	it('papel ausente ou desconhecido não passa', () => {
		expect(canManageAttachments(null)).toBe(false);
		expect(canManageAttachments(undefined)).toBe(false);
		expect(canManageAttachments('qualquer')).toBe(false);
	});

	it('a lista espelha a do backend', () => {
		expect([...PAPEIS_ANEXO]).toEqual(['owner', 'admin', 'recepcao']);
	});
});

describe('fmtBytes', () => {
	it('escala de B a MB', () => {
		expect(fmtBytes(512)).toBe('512 B');
		expect(fmtBytes(2048)).toBe('2 KB');
		expect(fmtBytes(5 * 1048576)).toBe('5.0 MB');
	});

	it('o teto de 50 MB sai legível — é o que a drop-zone anuncia', () => {
		expect(fmtBytes(50 * 1024 * 1024)).toBe('50.0 MB');
	});
});

describe('tipo do arquivo', () => {
	it('distingue imagem de PDF (decide o ícone da linha)', () => {
		expect(isImagem('image/png')).toBe(true);
		expect(isImagem('image/webp')).toBe(true);
		expect(isImagem('application/pdf')).toBe(false);
	});

	it('rotula curto, com JPEG por extenso', () => {
		expect(rotuloTipo('application/pdf')).toBe('PDF');
		expect(rotuloTipo('image/png')).toBe('PNG');
		expect(rotuloTipo('image/jpeg')).toBe('JPEG');
		expect(rotuloTipo('image/webp')).toBe('WEBP');
	});
});

describe('acceptAttr', () => {
	// O protótipo usava `image/*` ([`:973`]), que abre a porta para SVG — XML com <script>. O
	// seletor de arquivos oferece exatamente o que o servidor aceita, e nada mais.
	it('monta o accept a partir da allowlist do servidor, sem curinga', () => {
		const accept = acceptAttr(['application/pdf', 'image/png', 'image/jpeg', 'image/webp']);

		expect(accept).toBe('application/pdf,image/png,image/jpeg,image/webp');
		expect(accept).not.toContain('*');
		expect(accept).not.toContain('svg');
	});
});

describe('fmtData', () => {
	it('ISO vira dd/mm/aaaa', () => {
		expect(fmtData('2026-07-27T03:20:00.000000Z')).toBe('27/07/2026');
	});
});
