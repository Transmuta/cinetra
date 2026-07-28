import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';

import PatientUpcoming from './PatientUpcoming.svelte';
import type { HistorySession } from '$lib/server/patients';

const sessao = (over: Partial<HistorySession> = {}): HistorySession => ({
	id: 'att1',
	status: 'prevista',
	falta_justificada: false,
	package_id: null,
	appointment_id: 'a1',
	starts_at: '2026-09-25T18:00:00Z',
	ends_at: '2026-09-25T18:50:00Z',
	appointment_status: 'agendado',
	obs: null,
	tipo: 'Pilates',
	cor: '#0FB5A6',
	profissional: 'Dra. Ana',
	...over
});

afterEach(cleanup);

describe('PatientUpcoming', () => {
	// "Não tem nada marcado" é resposta, não ausência de resposta: é o que a recepção precisa ouvir
	// para oferecer horário. Por isso o cartão aparece vazio em vez de sumir.
	it('sem nada marcado, diz isso', () => {
		render(PatientUpcoming, { sessions: [], patientId: 'pac1' });
		expect(screen.getByText(/nenhuma sessão marcada/i)).toBeInTheDocument();
	});

	it('desenha data local, tipo e profissional', () => {
		render(PatientUpcoming, { sessions: [sessao()], patientId: 'pac1' });
		// 18:00Z = 15:00 em São Paulo
		expect(screen.getByText('25/09/2026 · 15:00')).toBeInTheDocument();
		expect(screen.getByText(/Pilates · Dra. Ana/)).toBeInTheDocument();
	});

	// A pergunta do cartão é "quando ele volta?" — a resposta é a PRIMEIRA linha, e ela é marcada
	// como tal para não se perder no meio das outras quatro.
	it('marca a primeira como a próxima', () => {
		render(PatientUpcoming, {
			sessions: [sessao(), sessao({ id: 'att2', starts_at: '2026-09-27T18:00:00Z' })],
			patientId: 'pac1'
		});
		// exato: `/próxima/i` casaria também com o título "Próximas sessões"
		expect(screen.getAllByText('próxima')).toHaveLength(1);
	});

	it('conta as sessões no cabeçalho', () => {
		render(PatientUpcoming, { sessions: [sessao(), sessao({ id: 'att2' })], patientId: 'pac1' });
		expect(screen.getByText('2')).toBeInTheDocument();
	});

	// O cartão para em 5 (`@proximas_na_ficha`): quem tem pacote de 20 sessões vê o resto na
	// agenda dele, não numa lista de 20 linhas que refaz o problema do doc 56.
	it('quando há mais, manda para a agenda do paciente', () => {
		render(PatientUpcoming, { sessions: [sessao()], more: true, patientId: 'pac1' });
		const link = screen.getByRole('link', { name: /ver na agenda/i });
		expect(link).toHaveAttribute('href', '/agenda?paciente=pac1');
	});

	it('sem mais nada, não oferece o link', () => {
		render(PatientUpcoming, { sessions: [sessao()], patientId: 'pac1' });
		expect(screen.queryByRole('link', { name: /ver na agenda/i })).not.toBeInTheDocument();
	});
});
