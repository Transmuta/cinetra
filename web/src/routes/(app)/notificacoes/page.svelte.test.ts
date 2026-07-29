import { describe, it, expect, vi, beforeEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// O mock de `enhance` CAPTURA o callback de cada form, em vez de ser um no-op cego: é o que
// permite exercitar o que acontece depois do submit (marcar lida → invalidar → navegar), que é
// justamente onde morava o bug do contador que não caía sem F5.
const forms = vi.hoisted(() => [] as Array<{ action: string; submit: unknown }>);
vi.mock('$app/forms', () => ({
	enhance: (node: HTMLFormElement, submit?: unknown) => {
		forms.push({ action: node.getAttribute('action') ?? '', submit });
		return { destroy() {} };
	}
}));
const nav = vi.hoisted(() => ({ goto: vi.fn(), invalidate: vi.fn() }));
vi.mock('$app/navigation', () => nav);

type SubmitResult = { result: { type: string }; update: () => Promise<void> };
type SubmitFn = (arg: unknown) => (r: SubmitResult) => Promise<void>;

// Roda o ciclo do enhance para o form de uma linha: chama o `SubmitFunction` e, com o que ele
// devolve, o callback que o SvelteKit invocaria ao voltar a resposta. O primeiro form `?/read`
// é sempre o da linha (o do botão de check vem depois, no mesmo <li>).
async function submitRow(result: { type: string }, update = vi.fn()) {
	const row = forms.find((f) => f.action === '?/read');
	await (row!.submit as SubmitFn)({})({ result, update });
	return update;
}

import Page from './+page.svelte';
import { meFixture } from '$lib/testing/fixtures';
import type { AppNotification } from '$lib/notifications';

function notif(over: Partial<AppNotification> = {}): AppNotification {
	return {
		id: over.id ?? 'n1',
		kind: over.kind ?? 'appointment_scheduled',
		title: over.title ?? 'Novo agendamento na sua agenda',
		body: over.body ?? 'Um agendamento foi adicionado em 27/07 às 08:00.',
		data: over.data ?? {},
		read: over.read ?? false,
		inserted_at: over.inserted_at ?? new Date().toISOString()
	};
}

// `theme`/`me` vêm dos layouts pais e o `PageData` os exige, ainda que esta tela não os use.
// `pageInfo`/`current` são do #54 — a caixa é paginada; sem `more`, o rodapé não aparece.
function data(
	notifications: AppNotification[],
	unread: number,
	page: { more?: boolean; current?: number; onlyUnread?: boolean } = {}
) {
	return {
		theme: null,
		me: meFixture({}),
		notifications,
		unread,
		pageInfo: { limit: 20, offset: 0, more: page.more ?? false },
		current: page.current ?? 1,
		onlyUnread: page.onlyUnread ?? false
	};
}

// `forms` acumula entre renders — sem zerar, um teste vê os forms do anterior.
beforeEach(() => {
	forms.length = 0;
	nav.goto.mockReset();
	nav.invalidate.mockReset();
});

describe('tela de notificações', () => {
	it('estado vazio quando não há nada', () => {
		const { getByText } = render(Page, { props: { data: data([], 0) } });
		expect(getByText('Nenhuma notificação')).toBeInTheDocument();
	});

	it('lista os títulos e o corpo', () => {
		const { getByText } = render(Page, {
			props: { data: data([notif({ title: 'Agendamento cancelado', body: 'foi cancelado' })], 1) }
		});
		expect(getByText('Agendamento cancelado')).toBeInTheDocument();
		expect(getByText('foi cancelado')).toBeInTheDocument();
	});

	it('com não-lidas mostra o contador e o "marcar todas"', () => {
		const { getByText, getByRole } = render(Page, {
			props: { data: data([notif()], 3) }
		});
		expect(getByText('3 não lidas')).toBeInTheDocument();
		expect(getByRole('button', { name: /marcar todas como lidas/i })).toBeInTheDocument();
	});

	it('sem não-lidas mostra "Tudo em dia" e esconde o "marcar todas"', () => {
		const { getByText, queryByRole } = render(Page, {
			props: { data: data([notif({ read: true })], 0) }
		});
		expect(getByText('Tudo em dia')).toBeInTheDocument();
		expect(queryByRole('button', { name: /marcar todas como lidas/i })).toBeNull();
	});

	// Bug relatado ao vivo: abrir uma notificação a marcava como lida, mas o badge do sino só
	// caía no F5. Causa: com destino, a linha fazia `goto(href)` e mais nada — e o contador do
	// layout tem `depends('app:unread')`, chave que só cai com um `invalidate` explícito.
	// Navegar para /agenda não reexecuta o load do layout (é o MESMO layout).
	describe('abrir uma notificação', () => {
		it('marca lida, derruba o contador e SÓ ENTÃO navega para o destino', async () => {
			render(Page, { props: { data: data([notif({ kind: 'slot_opened' })], 1) } });

			await submitRow({ type: 'success' });

			expect(nav.invalidate).toHaveBeenCalledWith('app:unread');
			expect(nav.goto).toHaveBeenCalledWith('/fila');
		});

		// Sem destino conhecido a linha fica onde está — o `update()` do enhance revalida tudo,
		// então o contador cai por esse caminho.
		it('sem destino, só revalida', async () => {
			// `role_changed` leva a /configuracoes/equipe; um kind sem destino é o que exercita o
			// outro ramo. `notificationHref` devolve `null` para os que não têm para onde ir.
			render(Page, { props: { data: data([notif({ kind: 'daily_digest', data: {} })], 1) } });

			const update = await submitRow({ type: 'failure' });

			expect(nav.goto).not.toHaveBeenCalled();
			expect(update).toHaveBeenCalled();
		});
	});

	// Pedido depois do teste ao vivo: dava para marcar lida SÓ abrindo a notificação, o que
	// arrastava a pessoa para outra tela. Agora cada linha não-lida tem o seu próprio botão.
	describe('marcar uma como lida sem sair da tela', () => {
		it('linha não lida oferece o botão', () => {
			const { getByRole } = render(Page, {
				props: { data: data([notif({ title: 'Vaga aberta' })], 1) }
			});
			expect(getByRole('button', { name: /marcar "vaga aberta" como lida/i })).toBeInTheDocument();
		});

		it('linha já lida não oferece', () => {
			const { queryByRole } = render(Page, {
				props: { data: data([notif({ title: 'Vaga aberta', read: true })], 0) }
			});
			expect(queryByRole('button', { name: /marcar "vaga aberta" como lida/i })).toBeNull();
		});

		// O ponto do botão é NÃO navegar: ele submete a mesma action e só revalida (o que derruba o
		// contador e tira o realce da linha). O teste exercita o CICLO do segundo form `?/read` —
		// e não a ausência de callback, que era um proxy de implementação: desde que o botão ganhou
		// estado de envio ele tem callback, e continua não navegando.
		it('não leva a pessoa para outra tela', async () => {
			render(Page, { props: { data: data([notif({ kind: 'slot_opened' })], 1) } });

			const marcar = forms.filter((f) => f.action === '?/read');
			expect(marcar.length).toBe(2);

			const update = vi.fn();
			await (marcar[1].submit as SubmitFn)({})({ result: { type: 'success' }, update });

			// `slot_opened` TEM destino (/fila) — se este form navegasse, seria aqui.
			expect(nav.goto).not.toHaveBeenCalled();
			expect(update).toHaveBeenCalled();
		});
	});

	describe('filtro', () => {
		// O filtro Todas/Não lidas vive na SIDEBAR do shell, como em Profissionais/Pacientes/Fila.
		// O corpo da tela não repete o controle — repetir daria dois lugares para o mesmo estado.
		it('não desenha abas no corpo da página', () => {
			const { queryAllByRole, queryByRole } = render(Page, { props: { data: data([notif()], 3) } });
			expect(queryAllByRole('tab')).toHaveLength(0);
			expect(queryByRole('tablist')).toBeNull();
		});

		// O vazio precisa dizer QUAL vazio: "nenhuma notificação" numa caixa cheia de lidas, só
		// porque o filtro está ligado, faria a pessoa achar que perdeu tudo.
		it('vazio com o filtro "não lidas" tem texto próprio', () => {
			const { getByText } = render(Page, {
				props: { data: data([], 0, { onlyUnread: true }) }
			});
			expect(getByText('Nenhuma não lida')).toBeInTheDocument();
		});

		// Bate-volta: o texto mandava a pessoa para a "aba Todas" — controle que deixou de
		// existir quando o filtro virou sidebar. Aponta para onde ele está de verdade.
		it('o vazio filtrado aponta para o menu, não para uma aba', () => {
			const { getByText, queryByText } = render(Page, {
				props: { data: data([], 0, { onlyUnread: true }) }
			});
			expect(getByText(/em "Todas", no menu ao lado/)).toBeInTheDocument();
			expect(queryByText(/na aba/)).toBeNull();
		});
	});

	describe('limpar tudo', () => {
		it('havendo notificações, oferece "Limpar tudo"', () => {
			const { getByRole } = render(Page, {
				props: { data: data([notif()], 1) }
			});
			expect(getByRole('button', { name: /limpar tudo/i })).toBeInTheDocument();
		});

		it('caixa vazia esconde o "Limpar tudo"', () => {
			const { queryByRole } = render(Page, { props: { data: data([], 0) } });
			expect(queryByRole('button', { name: /limpar tudo/i })).toBeNull();
		});

		// Apagar é irreversível (não há lixeira): a confirmação é o único freio.
		it('só apaga depois de confirmar', async () => {
			const { getByRole, queryByRole, getByText } = render(Page, {
				props: { data: data([notif()], 1) }
			});

			expect(queryByRole('button', { name: /apagar tudo/i })).toBeNull();

			await fireEvent.click(getByRole('button', { name: /limpar tudo/i }));

			expect(getByText(/não dá para desfazer/i)).toBeInTheDocument();
			expect(getByRole('button', { name: /apagar tudo/i })).toBeInTheDocument();
		});
	});

	// #54 — a caixa paginada.
	describe('paginação', () => {
		it('caixa que cabe numa página não mostra o rodapé', () => {
			const { queryByRole } = render(Page, { props: { data: data([notif()], 1) } });
			expect(queryByRole('button', { name: /próxima/i })).toBeNull();
			expect(queryByRole('button', { name: /anterior/i })).toBeNull();
		});

		it('havendo mais, o rodapé aparece com "Anterior" desabilitado na primeira', () => {
			const { getByRole } = render(Page, {
				props: { data: data([notif()], 1, { more: true }) }
			});
			expect(getByRole('button', { name: /anterior/i })).toBeDisabled();
			expect(getByRole('button', { name: /próxima/i })).toBeEnabled();
		});

		it('na última página, "Próxima" desabilita e "Anterior" continua', () => {
			const { getByRole } = render(Page, {
				props: { data: data([notif()], 1, { more: false, current: 2 }) }
			});
			expect(getByRole('button', { name: /próxima/i })).toBeDisabled();
			expect(getByRole('button', { name: /anterior/i })).toBeEnabled();
		});
	});
});
