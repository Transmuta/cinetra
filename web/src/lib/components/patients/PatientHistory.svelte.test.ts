import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';

import PatientHistory from './PatientHistory.svelte';
import type { HistorySession } from '$lib/server/patients';

const sessao = (over: Partial<HistorySession> = {}): HistorySession => ({
	id: 'att1',
	status: 'concluida',
	falta_justificada: false,
	package_id: null,
	appointment_id: 'a1',
	starts_at: '2026-07-20T11:00:00Z',
	ends_at: '2026-07-20T11:50:00Z',
	appointment_status: 'concluido',
	obs: null,
	tipo: 'Pilates',
	cor: '#0FB5A6',
	profissional: 'Dra. Ana',
	...over
});

afterEach(cleanup);

describe('PatientHistory', () => {
	it('sem sessões, mostra o placeholder', () => {
		render(PatientHistory, { sessions: [] });
		expect(screen.getByText(/nenhuma sessão registrada/i)).toBeInTheDocument();
	});

	it('desenha data local, tipo, profissional e o selo da presença', () => {
		render(PatientHistory, { sessions: [sessao()] });
		// 11:00Z = 08:00 em São Paulo
		expect(screen.getByText('20/07/2026 · 08:00')).toBeInTheDocument();
		expect(screen.getByText(/Pilates · Dra. Ana/)).toBeInTheDocument();
		expect(screen.getByText('Presente')).toBeInTheDocument();
	});

	// O ponto do modelo (attendance.ex:8): o bloco pode estar concluído com a presença faltando —
	// a ficha mostra o que aconteceu com ESTE paciente.
	it('mostra a presença, não o desfecho do bloco', () => {
		render(PatientHistory, {
			sessions: [sessao({ status: 'faltou', appointment_status: 'concluido' })]
		});
		expect(screen.getByText('Faltou')).toBeInTheDocument();
		expect(screen.queryByText('Presente')).not.toBeInTheDocument();
	});

	it('falta justificada aparece como tal (não conta para o paciente nem debita)', () => {
		render(PatientHistory, {
			sessions: [sessao({ status: 'faltou', falta_justificada: true })]
		});
		expect(screen.getByText('Faltou · justificada')).toBeInTheDocument();
	});

	it('sessão de pacote ganha a marca', () => {
		render(PatientHistory, { sessions: [sessao({ package_id: 'k1' })] });
		expect(screen.getByText('pacote')).toBeInTheDocument();
	});

	it('quando o servidor cortou a lista, avisa em vez de mentir', () => {
		render(PatientHistory, { sessions: [sessao()], more: true });
		expect(screen.getByText(/há mais no histórico/i)).toBeInTheDocument();
	});
});
