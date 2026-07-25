// Modelo de notificações in-app (doc 31), client-safe (sem segredo, sem fetch). Os tipos e os
// rótulos/ícones por espécie que a tela e o Rail compartilham.

export type NotificationKind =
	| 'appointment_scheduled'
	| 'appointment_rescheduled'
	| 'appointment_canceled'
	// A2 (doc 41 etapa 5): falta por participante e entrada em turma — as duas que o doc 31 §3a
	// deixou para "depois" porque esperavam a fatia de turma/pacote.
	| 'appointment_missed'
	| 'participant_added'
	| 'slot_opened'
	| 'member_joined';

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
}

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

// Para onde a notificação leva ao ser aberta. Sem parâmetro fino (v1): agenda/fila abrem no
// estado padrão; equipe é a tela do convite aceito. `null` = sem destino (só marca lida).
export function notificationHref(kind: NotificationKind): string | null {
	switch (kind) {
		case 'appointment_scheduled':
		case 'appointment_rescheduled':
		case 'appointment_canceled':
		case 'appointment_missed':
		case 'participant_added':
			return '/agenda';
		case 'slot_opened':
			return '/fila';
		case 'member_joined':
			return '/configuracoes/equipe';
		default:
			return null;
	}
}
