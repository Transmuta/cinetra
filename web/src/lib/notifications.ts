// Modelo de notificações in-app (doc 31), client-safe (sem segredo, sem fetch). Os tipos e os
// rótulos/ícones por espécie que a tela e o Rail compartilham.

import type { PageInfo } from '$lib/pagination';

export type NotificationKind =
	| 'appointment_scheduled'
	| 'appointment_rescheduled'
	| 'appointment_canceled'
	// A2 (doc 41 etapa 5): falta por participante e entrada em turma — as duas que o doc 31 §3a
	// deixou para "depois" porque esperavam a fatia de turma/pacote.
	| 'appointment_missed'
	| 'participant_added'
	// Bate-volta da Onda 3 (doc 43 §5b): a massa por pacote é UM evento, não N.
	| 'package_bulk_adjusted'
	| 'slot_opened'
	| 'member_joined'
	// Onda 4 / Frente 10: governança (#50), fila urgente (#48) e os dois lembretes por cron (#51).
	| 'role_changed'
	| 'member_removed'
	| 'waitlist_urgent'
	| 'daily_digest'
	| 'session_soon';

export interface AppNotification {
	id: string;
	kind: NotificationKind;
	title: string;
	body: string;
	data: Record<string, unknown>;
	read: boolean;
	inserted_at: string;
}

export interface NotificationsData {
	notifications: AppNotification[];
	unread: number;
	// #54: a caixa passou a ser paginada. `total` não vem (ver `$lib/pagination`).
	page: PageInfo;
}

// Tamanho de página da caixa. Menor que o das listas de cadastro (50): a caixa é lida de relance,
// não estudada — e o "carregar mais" é um clique, não uma navegação de trabalho.
export const PAGE_SIZE = 20;

// Tempo relativo curto (pt-BR) para o carimbo de cada notificação. `now` injetável para o teste
// não depender do relógio de parede.
export function relativeTime(iso: string, now: Date = new Date()): string {
	const then = new Date(iso);
	const min = Math.floor((now.getTime() - then.getTime()) / 60_000);
	if (min < 1) return 'agora';
	if (min < 60) return `há ${min} min`;
	const h = Math.floor(min / 60);
	if (h < 24) return `há ${h} h`;
	const d = Math.floor(h / 24);
	if (d === 1) return 'ontem';
	if (d < 7) return `há ${d} dias`;
	return then.toLocaleDateString('pt-BR');
}

// A data que a notificação carrega, quando carrega uma. Descartada se não for `YYYY-MM-DD`:
// `data` é payload livre (jsonb), e o destino de navegação não deve confiar nele sem olhar.
function dateParam(data: Record<string, unknown>): string | null {
	const date = data?.date;
	return typeof date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : null;
}

// Para onde a notificação leva ao ser aberta (#56 — deep-link fino).
//
// Antes todo aviso de agenda caía em `/agenda` no estado padrão, ou seja, no dia de HOJE: abrir
// "seu paciente de quinta foi remarcado" mostrava a agenda de hoje, e a pessoa tinha de navegar
// até lá na mão. O `data` da notificação já trazia o `date` desde o começo — faltava usá-lo.
//
// `null` = sem destino conhecido (a linha só marca lida).
export function notificationHref(n: {
	kind: NotificationKind;
	data?: Record<string, unknown>;
}): string | null {
	const data = n.data ?? {};
	const date = dateParam(data);
	const agenda = date ? `/agenda?date=${date}` : '/agenda';

	switch (n.kind) {
		// Todos carregam o dia do bloco — é o que torna o link útil.
		case 'appointment_scheduled':
		case 'appointment_rescheduled':
		case 'appointment_canceled':
		case 'appointment_missed':
		case 'participant_added':
		case 'daily_digest':
		case 'session_soon':
			return agenda;

		// A massa por pacote é um evento de N sessões em datas diferentes: não há um dia só para
		// onde levar, então continua abrindo a agenda no padrão.
		case 'package_bulk_adjusted':
			return '/agenda';

		case 'slot_opened':
			return '/fila';

		// O aviso É sobre a prioridade: a fila já abre filtrada no que motivou o sino.
		case 'waitlist_urgent':
			return '/fila?prio=urgente';

		case 'member_joined':
		case 'member_removed':
		case 'role_changed':
			return '/configuracoes/equipe';

		default:
			return null;
	}
}
