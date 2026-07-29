import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

// `page.url` é lido pelo AuthForm (o "usar outro e-mail" volta para o próprio caminho, e agora
// também o aviso de entrada que não deu certo). Cada teste troca a URL antes de renderizar.
const app = vi.hoisted(() => ({ page: { url: new URL('http://localhost/entrar') } }));
vi.mock('$app/state', () => app);

import Entrar from './+page.svelte';

const props = {
	data: { canonical: 'https://cinetra.app/entrar', origem: 'https://cinetra.app' },
	form: null
} as never;

function em(query: string) {
	app.page.url = new URL(`http://localhost/entrar${query}`);
}

afterEach(cleanup);

// As quatro portas de entrada que podem falhar devolvem a pessoa para `/entrar` com o MESMO
// parâmetro, `erro`, e dois valores: `erro=link` (magic link inválido/expirado — `auth/callback`,
// duas saídas) e `erro=google` (a API não devolveu Location ou não assinou a sessão —
// `auth/google` e `auth/user/google/callback`). Ninguém lia esse parâmetro: a tela de login
// reaparecia idêntica, sem uma palavra, e o sintoma que sobrava era "cliquei no link e não entrei".
//
// **A URL semeada aqui é a que os `redirect(303, …)` de fato emitem.** A primeira versão destes
// testes semeava `?link`/`?google` — uma forma que nenhuma rota produz —, e por isso ficou verde
// sobre um componente que não acendia aviso nenhum no fluxo real.
describe('/entrar — entrada que não deu certo', () => {
	it('erro=link diz que o link não vale mais e manda pedir outro', () => {
		em('?erro=link');
		render(Entrar, { props });

		// Pelo `role=alert`: o texto "link de acesso" também é o rótulo do botão de envio, e casar
		// por texto solto passaria mesmo sem aviso nenhum na tela.
		expect(screen.getByRole('alert')).toHaveTextContent(/expirou ou já foi usado/i);
	});

	it('erro=google explica a falha e aponta o outro caminho', () => {
		em('?erro=google');
		render(Entrar, { props });

		expect(screen.getByRole('alert')).toHaveTextContent(/não foi possível entrar com o google/i);
	});

	// O aviso é dado do servidor, não texto interno: nenhuma das duas mensagens cita código,
	// status ou nome de rota.
	it('o aviso não vaza detalhe de sistema', () => {
		em('?erro=link');
		const { container } = render(Entrar, { props });

		expect(container.textContent).not.toMatch(/token|jwt|401|callback|magic/i);
	});

	it('sem erro na query, nenhum aviso', () => {
		em('');
		render(Entrar, { props });

		expect(screen.queryByRole('alert')).toBeNull();
	});

	// Query desconhecida não é sinal de erro: `?utm_source=…` não pode virar aviso de falha.
	it('query desconhecida não inventa aviso', () => {
		em('?xpto=1');
		render(Entrar, { props });

		expect(screen.queryByRole('alert')).toBeNull();
	});

	// O mapa é fechado, e é ele quem garante que nada vindo da URL chega à tela: `?erro=<script>…`
	// não pode virar texto, nem "erro desconhecido".
	it('valor de erro fora do mapa não vira aviso', () => {
		em('?erro=xpto');
		render(Entrar, { props });

		expect(screen.queryByRole('alert')).toBeNull();
	});
});
