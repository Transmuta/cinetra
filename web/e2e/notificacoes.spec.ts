import { test, expect, abrirAgenda, joinDoCanal, sino } from './fixtures';
import { convidar, emailUnico, entrarPeloConvite } from './helpers';

/**
 * O sino: acende sozinho quando algo acontece, e o contador **cai sem F5** quando a notificação é
 * aberta.
 *
 * A segunda metade é regressão de um bug visto ao vivo e consertado em
 * `notificacoes/+page.svelte`: abrir uma notificação a marcava lida, mas o badge só caía no F5. O
 * contador vem do load do LAYOUT (`depends('app:unread')`), e navegar com `goto` **não** reexecuta
 * load de layout — é o mesmo layout. O conserto é um `invalidate('app:unread')` explícito antes do
 * `goto`, e a suíte de unidade não o protege: o mock de `enhance` é no-op, então a navegação nem
 * acontece ali. Apagar aquela linha tem de deixar este teste vermelho — é a única guarda que ela
 * tem.
 *
 * O gatilho é um convite aceito (`member_joined`, doc 31 §3c): dos eventos da v1 é o que precisa de
 * menos cenário e o único com **outro** ator de verdade — o fan-out suprime o autor, então nada que
 * a própria dona faça encheria a caixa dela.
 */
test.describe('Sino de notificações', () => {
	test('acende pelo canal e o contador cai ao abrir, sem recarregar', async ({
		page,
		browser,
		request,
		clinica
	}) => {
		const entrouNoSino = joinDoCanal(page, `notifications:${clinica.id}`);
		await abrirAgenda(page, clinica);
		await entrouNoSino;

		// Caixa vazia: o nome acessível do sino é o contrato do badge (sem número, sem badge).
		await expect(sino(page)).toHaveAccessibleName('Notificações');

		const convidada = emailUnico('rita');
		await convidar(clinica.api, {
			email: convidada,
			nome: 'Rita Recepção',
			papel: 'recepcao'
		});

		// Rita aceita em OUTRO contexto (outra sessão, outro cookie) — é o que faz a notificação
		// existir para a dona, que continua com a agenda aberta e sem tocar em nada.
		const contextoDaRita = await browser.newContext();
		const paginaDaRita = await contextoDaRita.newPage();
		await entrarPeloConvite(paginaDaRita, request, convidada);
		await contextoDaRita.close();

		// 1) Acendeu sozinho: veio pelo canal `notifications:<clinic>` → `invalidate('app:unread')`.
		await expect(sino(page)).toHaveAccessibleName('Notificações (1 não lidas)');

		// 2) Abrir a notificação leva ao destino E zera o contador na mesma navegação.
		await sino(page).click();
		// No `main`: o topbar do shell também tem um `<h1>` com o nome da seção.
		await expect(page.getByRole('main').getByRole('heading', { name: 'Notificações' })).toBeVisible();

		// `^`: a linha inteira é um botão ("Novo membro na equipe agora"), e ao lado dela há o
		// botão de check, cujo nome COMEÇA com "Marcar" e cita o mesmo título.
		await page.getByRole('button', { name: /^Novo membro na equipe/ }).click();

		// O deep-link de `member_joined` (#56) é a tela de equipe.
		await expect(page).toHaveURL(/\/configuracoes\/equipe$/);
		// E o badge sumiu sem que ninguém recarregasse — o `invalidate` antes do `goto`.
		await expect(sino(page)).toHaveAccessibleName('Notificações');

		// A recém-chegada está na lista: prova que o que acendeu o sino aconteceu de verdade, e não
		// que o contador subiu por conta própria.
		await expect(page.getByText('Rita Recepção')).toBeVisible();
	});
});
