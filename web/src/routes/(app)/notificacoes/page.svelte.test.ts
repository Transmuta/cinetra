import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';

// enhance/goto como no-op (não há runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));
vi.mock('$app/navigation', () => ({ goto: vi.fn() }));

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
function data(notifications: AppNotification[], unread: number) {
	return { theme: null, me: meFixture({}), notifications, unread };
}

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
});
