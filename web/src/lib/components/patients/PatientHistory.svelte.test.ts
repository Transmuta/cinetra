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
		// Texto do protótipo ([`:2822`]) desde o doc 51 §L6.
		expect(screen.getByText(/sem atendimentos registrados/i)).toBeInTheDocument();
	});

	// §L6: o protótipo mostra quantas sessões existem no canto do cabeçalho; a versão anterior
	// não mostrava nenhuma contagem.
	it('conta as sessões no cabeçalho', () => {
		render(PatientHistory, { sessions: [sessao(), sessao({ id: 'att2' })] });
		expect(screen.getByText('2')).toBeInTheDocument();
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

	// doc 56: o aviso existia e era um beco sem saída — informava a truncagem e não oferecia o
	// caminho. Agora a ficha abre com 8 linhas e o resto é um link que sobe o teto pela URL.
	it('quando o servidor cortou a lista, oferece o caminho para o resto', () => {
		render(PatientHistory, { sessions: [sessao()], more: true });
		const link = screen.getByRole('link', { name: /ver hist(ó|o)rico completo/i });
		expect(link).toHaveAttribute('href', '?historico=200');
	});

	it('lista inteira na tela não oferece "ver mais"', () => {
		render(PatientHistory, { sessions: [sessao()] });
		expect(screen.queryByRole('link', { name: /ver hist(ó|o)rico completo/i })).not.toBeInTheDocument();
	});
});
