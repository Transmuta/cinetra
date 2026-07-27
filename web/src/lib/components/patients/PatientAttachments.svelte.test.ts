import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import PatientAttachments from './PatientAttachments.svelte';
import { currentToast, dismissToast } from '$lib/toast.svelte';
import type { Attachment, AttachmentLimits } from '$lib/attachments';

const limites: AttachmentLimits = {
	max_bytes: 50 * 1024 * 1024,
	max_por_paciente: 100,
	tipos: ['application/pdf', 'image/png', 'image/jpeg', 'image/webp']
};

const anexo = (over: Partial<Attachment> = {}): Attachment => ({
	id: 'ax1',
	nome: 'laudo.pdf',
	content_type: 'application/pdf',
	bytes: 204800,
	status: 'disponivel',
	inserted_at: '2026-07-27T03:20:00.000000Z',
	...over
});

function montar(over: Partial<Parameters<typeof render>[1]> = {}) {
	const onChanged = vi.fn();

	render(PatientAttachments, {
		patientId: 'p1',
		attachments: [],
		limites,
		onChanged,
		...(over as object)
	});

	return { onChanged };
}

beforeEach(() => {
	vi.restoreAllMocks();
	dismissToast();
});

afterEach(cleanup);

describe('PatientAttachments — estados da seção', () => {
	it('sem anexos, mostra a drop-zone com os limites VINDOS DO SERVIDOR', () => {
		montar();

		expect(screen.getByText(/arraste um arquivo ou clique para enviar/i)).toBeInTheDocument();
		// Os números não são repetidos no cliente: se o servidor mudar o teto, a tela acompanha.
		expect(screen.getByText(/PDF, PNG, JPEG, WEBP · até 50\.0 MB por arquivo/)).toBeInTheDocument();
		expect(screen.getByText(/nenhum anexo ainda/i)).toBeInTheDocument();
	});

	it('sem storage configurado (503), explica em vez de oferecer um campo inútil', () => {
		montar({ limites: null });

		expect(screen.getByText(/storage de anexos não está configurado/i)).toBeInTheDocument();
		expect(screen.queryByText(/arraste um arquivo/i)).toBeNull();
	});

	it('lista nome, tipo, tamanho e data — e conta os arquivos no cabeçalho', () => {
		montar({ attachments: [anexo(), anexo({ id: 'ax2', nome: 'raio-x.png', content_type: 'image/png' })] });

		expect(screen.getByText('laudo.pdf')).toBeInTheDocument();
		expect(screen.getByText('raio-x.png')).toBeInTheDocument();
		expect(screen.getByText(/PDF · 200 KB · 27\/07\/2026/)).toBeInTheDocument();
		expect(screen.getByText('2 arquivos')).toBeInTheDocument();
	});

	it('no limite de anexos, troca a drop-zone pela explicação', () => {
		montar({
			limites: { ...limites, max_por_paciente: 1 },
			attachments: [anexo()]
		});

		expect(screen.getByText(/atingiu o limite de 1 anexos/i)).toBeInTheDocument();
		expect(screen.queryByText(/arraste um arquivo/i)).toBeNull();
	});

	it('o accept do input não abre para `image/*` (SVG ficaria dentro)', () => {
		const { container } = render(PatientAttachments, {
			patientId: 'p1',
			attachments: [],
			limites,
			onChanged: vi.fn()
		});

		const input = container.querySelector('input[type="file"]');
		expect(input?.getAttribute('accept')).toBe(limites.tipos.join(','));
		expect(input?.getAttribute('accept')).not.toContain('*');
	});
});

describe('PatientAttachments — abrir', () => {
	it('pede uma URL NOVA a cada clique e abre em outra aba', async () => {
		const open = vi.spyOn(window, 'open').mockImplementation(() => null);
		const fetchMock = vi
			.spyOn(globalThis, 'fetch')
			.mockResolvedValue(
				new Response(JSON.stringify({ ok: true, url: 'https://bucket/assinada' }), { status: 200 })
			);

		montar({ attachments: [anexo()] });

		await userEvent.click(screen.getByRole('button', { name: /abrir laudo\.pdf/i }));

		await waitFor(() => expect(open).toHaveBeenCalled());

		// A URL dura minutos e a EMISSÃO é o que fica na trilha LGPD: guardar e reusar quebraria
		// as duas coisas, então cada clique passa pelo BFF.
		expect(fetchMock).toHaveBeenCalledWith(
			'/pacientes/p1/anexos/ax1?acao=download',
			expect.objectContaining({ method: 'POST' })
		);
		expect(open).toHaveBeenCalledWith('https://bucket/assinada', '_blank', 'noopener,noreferrer');
	});

	it('falha ao abrir avisa e não abre aba nenhuma', async () => {
		const open = vi.spyOn(window, 'open').mockImplementation(() => null);
		vi.spyOn(globalThis, 'fetch').mockResolvedValue(
			new Response(JSON.stringify({ ok: false, error: 'Registro não encontrado.' }), { status: 404 })
		);

		montar({ attachments: [anexo()] });
		await userEvent.click(screen.getByRole('button', { name: /abrir laudo\.pdf/i }));

		// O toast é global (renderizado pelo `+layout`), então a asserção é sobre o STORE — não
		// há pill dentro deste componente para procurar no DOM.
		await waitFor(() => expect(currentToast()?.message).toBe('Registro não encontrado.'));
		expect(currentToast()?.variant).toBe('error');
		expect(open).not.toHaveBeenCalled();
	});
});

describe('PatientAttachments — remover', () => {
	it('pergunta antes, e o aviso diz que os BYTES vão embora', async () => {
		montar({ attachments: [anexo()] });

		await userEvent.click(screen.getByRole('button', { name: /remover laudo\.pdf/i }));

		expect(screen.getByRole('heading', { name: 'Remover anexo' })).toBeInTheDocument();
		expect(screen.getByText(/apagado do storage, não só desta lista/i)).toBeInTheDocument();
	});

	it('confirmado, chama o DELETE e recarrega a ficha', async () => {
		const fetchMock = vi
			.spyOn(globalThis, 'fetch')
			.mockResolvedValue(new Response(JSON.stringify({ ok: true }), { status: 200 }));

		const { onChanged } = montar({ attachments: [anexo()] });

		await userEvent.click(screen.getByRole('button', { name: /remover laudo\.pdf/i }));
		await userEvent.click(screen.getByRole('button', { name: 'Remover' }));

		await waitFor(() => expect(onChanged).toHaveBeenCalled());
		expect(fetchMock).toHaveBeenCalledWith(
			'/pacientes/p1/anexos/ax1',
			expect.objectContaining({ method: 'DELETE' })
		);
	});
});

describe('PatientAttachments — renomear', () => {
	it('abre com o nome atual e manda o PATCH', async () => {
		const fetchMock = vi
			.spyOn(globalThis, 'fetch')
			.mockResolvedValue(new Response(JSON.stringify({ ok: true }), { status: 200 }));

		const { onChanged } = montar({ attachments: [anexo()] });

		await userEvent.click(screen.getByRole('button', { name: /renomear laudo\.pdf/i }));

		const campo = screen.getByLabelText('Nome do anexo');
		expect(campo).toHaveValue('laudo.pdf');

		await userEvent.clear(campo);
		await userEvent.type(campo, 'Ressonância joelho.pdf');
		await userEvent.click(screen.getByRole('button', { name: 'Salvar' }));

		await waitFor(() => expect(onChanged).toHaveBeenCalled());

		const [, init] = fetchMock.mock.calls.at(-1)!;
		expect(init).toMatchObject({ method: 'PATCH' });
		expect(JSON.parse(String((init as RequestInit).body))).toEqual({
			nome: 'Ressonância joelho.pdf'
		});
	});

	it('nome vazio não salva', async () => {
		montar({ attachments: [anexo()] });

		await userEvent.click(screen.getByRole('button', { name: /renomear laudo\.pdf/i }));
		await userEvent.clear(screen.getByLabelText('Nome do anexo'));

		expect(screen.getByRole('button', { name: 'Salvar' })).toBeDisabled();
	});
});
