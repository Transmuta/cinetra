import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import UserAvatar from './UserAvatar.svelte';

describe('UserAvatar', () => {
	it('sem foto: iniciais, com fundo E cor de texto vindos do mesmo lugar', () => {
		const { container } = render(UserAvatar, { props: { nome: 'Ana Paula' } });
		const box = container.querySelector('div');

		expect(box).toHaveTextContent('AP');
		// `avatarStyle` devolve os dois juntos de propósito (ver avatar.ts): a metade da cor de
		// texto ficando por conta da classe era o defeito que ele existe para fechar.
		expect(box?.getAttribute('style')).toMatch(/background:.*color:/);
	});

	it('com foto: renderiza a imagem assinada, sem iniciais', () => {
		const url = 'https://conta.r2.cloudflarestorage.com/user/u1/avatar.png?X-Amz-Signature=abc';
		const { container, queryByText } = render(UserAvatar, {
			props: { nome: 'Ana Paula', url }
		});
		const img = container.querySelector('img');

		expect(img).toHaveAttribute('src', url);
		expect(queryByText('AP')).not.toBeInTheDocument();
	});

	it('a foto é decorativa por padrão (alt vazio) e não vaza referrer para o bucket', () => {
		// O nome da pessoa já está escrito ao lado em ambos os usos; anunciar de novo é ruído
		// para leitor de tela. `no-referrer` porque a URL da página não tem por que viajar junto
		// do pedido da imagem.
		const { container } = render(UserAvatar, {
			props: { nome: 'Ana Paula', url: 'https://x/y.png' }
		});
		const img = container.querySelector('img');

		expect(img).toHaveAttribute('alt', '');
		expect(img).toHaveAttribute('referrerpolicy', 'no-referrer');
	});

	it('url nula cai nas iniciais (o /me devolve null quando não há foto)', () => {
		const { container } = render(UserAvatar, { props: { nome: 'Bruno Lima', url: null } });

		expect(container.querySelector('img')).toBeNull();
		expect(container.querySelector('div')).toHaveTextContent('BL');
	});
});
