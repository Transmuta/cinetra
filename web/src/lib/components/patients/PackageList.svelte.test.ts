import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import PackageList from './PackageList.svelte';
import type { Package } from '$lib/packages';

const pkg = (over: Partial<Package> = {}): Package => ({
	id: 'k1',
	nome: 'Pilates 10',
	status: 'ativo',
	total: 10,
	usadas: 3,
	restantes: 7,
	acabando: false,
	falta_punitiva: true,
	cor: '#0FB5A6',
	data_inicio: '2026-07-20',
	appointment_type_id: 't1',
	grade: { dows: [1, 3], horarios: { '1': '08:00', '3': '09:00' }, professional_id: 'pr1' },
	sessoes: [
		{ attendance_id: 's1', appointment_id: 'p1', starts_at: '2026-07-20T11:00:00Z', estado: 'concluida' },
		{ attendance_id: 's2', appointment_id: 'p2', starts_at: '2026-07-22T11:00:00Z', estado: 'concluida' },
		{ attendance_id: 's3', appointment_id: 'p3', starts_at: '2026-07-27T11:00:00Z', estado: 'falta' },
		{ attendance_id: 's4', appointment_id: 'p4', starts_at: '2026-07-30T11:00:00Z', estado: 'proxima' },
		{ attendance_id: 's5', appointment_id: 'p5', starts_at: '2026-08-03T11:00:00Z', estado: 'agendada' }
	],
	...over
});

const professionals = [{ id: 'pr1', nome: 'Ana Prado' }];

const appointmentTypes = [
	{
		id: 't1',
		nome: 'Pilates Solo',
		duracao_minutos: 50,
		cor: '#0FB5A6',
		icon: 'Activity',
		sigla: 'PIL',
		grupo: false,
		capacidade: null,
		ativo: true
	}
];

const upcoming = [
	{ id: 's1', package_id: 'k1', starts_at: '2026-07-30T11:00:00Z' },
	{ id: 's2', package_id: null, starts_at: '2026-07-31T11:00:00Z' }
];

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const base = (over: Record<string, unknown> = {}): any => ({
	packages: [pkg()],
	professionals,
	appointmentTypes,
	upcoming,
	timezone: 'America/Sao_Paulo',
	...over
});

// O menu ⋯ é onde as ações moram agora (doc 69 §7 item 6): o cartão informa, o menu executa.
async function abreMenu() {
	await userEvent.click(screen.getByRole('button', { name: /gerir pacote/i }));
}

afterEach(cleanup);

describe('PackageList — o cartão responde', () => {
	it('lista vazia mostra o placeholder', () => {
		render(PackageList, base({ packages: [] }));
		expect(screen.getByText(/nenhum pacote ainda/i)).toBeInTheDocument();
	});

	it('identifica o pacote pelo TIPO (nome e duração), não só pelo nome digitado', () => {
		render(PackageList, base());
		expect(screen.getByText('Pilates Solo')).toBeInTheDocument();
		expect(screen.getByText(/50\s*min/)).toBeInTheDocument();
	});

	it('tipo desconhecido (arquivado ou não carregado) cai no nome do pacote', () => {
		render(PackageList, base({ appointmentTypes: [] }));
		expect(screen.getByText('Pilates 10')).toBeInTheDocument();
	});

	it('mostra o código curto do pacote (o "PIL-2607" que se fala ao telefone)', () => {
		render(PackageList, base());
		expect(screen.getByText('PIL-2607')).toBeInTheDocument();
	});

	it('mostra a grade legível: dias, horários e o profissional', () => {
		render(PackageList, base());
		expect(screen.getByText(/Seg 08:00, Qua 09:00 · Ana Prado/)).toBeInTheDocument();
	});

	it('o contador é usadas/total com os restantes ao lado (não o ambíguo "X de Y restantes")', () => {
		render(PackageList, base());
		expect(screen.getByText('3')).toBeInTheDocument();
		expect(screen.getByText('/10')).toBeInTheDocument();
		expect(screen.getByText(/7 restantes/)).toBeInTheDocument();
		expect(screen.queryByText(/7 de 10 restantes/)).not.toBeInTheDocument();
	});

	it('mostra a PRÓXIMA sessão daquele pacote', () => {
		render(PackageList, base());
		expect(screen.getByText(/Próxima:/)).toBeInTheDocument();
		expect(screen.getByText(/30\/07/)).toBeInTheDocument();
	});

	// A trilha é o que o contador NÃO diz: quais já foram, qual faltou, qual é a próxima.
	it('desenha uma bolinha por sessão, com o estado no title', () => {
		render(PackageList, base());
		const trilha = screen.getByRole('list', { name: /sessões do pacote/i });
		const bolinhas = within(trilha).getAllByRole('listitem');

		expect(bolinhas).toHaveLength(5);
		expect(bolinhas[2].getAttribute('title')).toMatch(/Falta/);
		expect(bolinhas[3].getAttribute('title')).toMatch(/Próxima/);
	});

	it('pacote sem trilha (série ainda materializando) não quebra o cartão', () => {
		render(PackageList, base({ packages: [pkg({ sessoes: [] })] }));
		expect(screen.queryByRole('list', { name: /sessões do pacote/i })).not.toBeInTheDocument();
	});

	it('pacote sem próxima diz isso em vez de calar', () => {
		render(PackageList, base({ upcoming: [] }));
		expect(screen.getByText(/sem próxima sessão/i)).toBeInTheDocument();
	});
});

describe('PackageList — estado', () => {
	it('o cabeçalho conta só os ATUAIS (achado §6.3)', () => {
		render(
			PackageList,
			base({
				packages: [
					pkg({ id: 'a', status: 'ativo' }),
					pkg({ id: 'b', status: 'pausado' }),
					pkg({ id: 'c', status: 'cancelado' }),
					pkg({ id: 'd', status: 'concluido' })
				]
			})
		);
		expect(screen.getByRole('heading', { name: /Pacotes.*2 ativos/ })).toBeInTheDocument();
	});

	it('chip "Acabando" quando o domínio diz que está acabando (achado §6.4)', () => {
		render(PackageList, base({ packages: [pkg({ acabando: true, restantes: 2, usadas: 8 })] }));
		expect(screen.getByText('Acabando')).toBeInTheDocument();
	});

	it('0 restantes lê "Completo" — o status só vira concluído ao arquivar (D1)', () => {
		render(PackageList, base({ packages: [pkg({ restantes: 0, usadas: 10 })] }));
		expect(screen.getByText('Completo')).toBeInTheDocument();
	});

	it('pausado explica que as sessões estão fora da agenda e oferece Retomar em destaque', () => {
		render(PackageList, base({ packages: [pkg({ status: 'pausado' })], canManage: true }));
		expect(screen.getByText(/fora da agenda/i)).toBeInTheDocument();
		expect(screen.getByText(/validade estendida/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /Retomar pacote/ })).toBeInTheDocument();
	});

	it('acabando ganha a caixa de aviso com o que falta', () => {
		render(PackageList, base({ packages: [pkg({ acabando: true, restantes: 1, usadas: 9 })] }));
		expect(screen.getByText('Pacote acabando')).toBeInTheDocument();
		expect(screen.getByText(/Falta 1 sessão para concluir/)).toBeInTheDocument();
	});

	// No histórico o pacote já não pede nada — o contador e a trilha contam a história.
	it('pacote do histórico não repete a caixa de contexto', async () => {
		render(
			PackageList,
			base({ packages: [pkg({ id: 'z', status: 'concluido', restantes: 0, usadas: 10 })] })
		);
		await userEvent.click(screen.getByRole('button', { name: /Histórico/ }));

		expect(screen.getByText('Concluído')).toBeInTheDocument();
		expect(screen.queryByText('Pacote concluído')).not.toBeInTheDocument();
	});

	it('cancelados e concluídos saem da lista principal e vão para o histórico recolhido', async () => {
		render(
			PackageList,
			base({ packages: [pkg({ id: 'a' }), pkg({ id: 'b', status: 'cancelado', nome: 'RPG 5' })] })
		);

		expect(screen.queryByText('Cancelado')).not.toBeInTheDocument();

		await userEvent.click(screen.getByRole('button', { name: /Histórico/ }));
		expect(screen.getByText('Cancelado')).toBeInTheDocument();
	});
});

describe('PackageList — ações no menu', () => {
	it('sem canManage não há menu nem "novo pacote"', () => {
		render(PackageList, base());
		expect(screen.queryByText('Novo pacote')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /gerir pacote/i })).not.toBeInTheDocument();
	});

	it('"Novo pacote" chama onNew', async () => {
		const onNew = vi.fn();
		render(PackageList, base({ packages: [], canManage: true, onNew }));
		await userEvent.click(screen.getByText('Novo pacote'));
		expect(onNew).toHaveBeenCalledOnce();
	});

	it('ativo: o menu traz Pausar, Ajustar grade e Cancelar', async () => {
		render(PackageList, base({ canManage: true, onGrade: vi.fn() }));
		await abreMenu();
		expect(screen.getByRole('button', { name: /Pausar pacote/ })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /Ajustar grade/ })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /Cancelar pacote/ })).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /Retomar pacote/ })).not.toBeInTheDocument();
	});

	// "Ajustar sessões" (a massa) saiu: mexer nas próximas é o AJUSTE DE GRADE, que faz o mesmo e
	// ainda alcança os dias da semana. Duas portas para a mesma intenção confundiam a recepção.
	it('não há mais "Ajustar sessões" no menu', async () => {
		render(PackageList, base({ canManage: true, onGrade: vi.fn() }));
		await abreMenu();
		expect(screen.queryByRole('button', { name: /Ajustar sessões/ })).not.toBeInTheDocument();
	});

	it('pausado não oferece o ajuste de grade — as sessões estão seguradas, fora da agenda', async () => {
		render(
			PackageList,
			base({ packages: [pkg({ status: 'pausado' })], canManage: true, onGrade: vi.fn() })
		);
		await abreMenu();
		expect(screen.queryByRole('button', { name: /Ajustar grade/ })).not.toBeInTheDocument();
	});

	it('"Arquivar" só aparece com 0 restantes (D1: é a porta manual para concluído)', async () => {
		render(PackageList, base({ canManage: true }));
		await abreMenu();
		expect(screen.queryByRole('button', { name: /Arquivar/ })).not.toBeInTheDocument();

		cleanup();
		render(PackageList, base({ packages: [pkg({ restantes: 0, usadas: 10 })], canManage: true }));
		await abreMenu();
		expect(screen.getByRole('button', { name: /Arquivar/ })).toBeInTheDocument();
	});

	it('cancelado/concluído não têm menu de ciclo de vida', async () => {
		render(PackageList, base({ packages: [pkg({ status: 'cancelado' })], canManage: true }));
		await userEvent.click(screen.getByRole('button', { name: /Histórico/ }));
		expect(screen.queryByRole('button', { name: /gerir pacote/i })).not.toBeInTheDocument();
	});

	it('o menu traz o +/− do ADR-011 e os atalhos de grade e trilha', async () => {
		const onGrade = vi.fn();
		const onSessions = vi.fn();
		render(PackageList, base({ canManage: true, onGrade, onSessions }));
		await abreMenu();

		expect(screen.getByRole('button', { name: /Somar sessão/ })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /Tirar sessão/ })).toBeInTheDocument();

		await userEvent.click(screen.getByRole('button', { name: /Ajustar grade/ }));
		expect(onGrade).toHaveBeenCalledWith(expect.objectContaining({ id: 'k1' }));

		await abreMenu();
		await userEvent.click(screen.getByRole('button', { name: /Ver sessões/ }));
		expect(onSessions).toHaveBeenCalledWith(expect.objectContaining({ id: 'k1' }));
	});

	it('Cancelar abre a confirmação DIZENDO quantas sessões serão liberadas', async () => {
		render(PackageList, base({ canManage: true }));
		await abreMenu();
		await userEvent.click(screen.getByRole('button', { name: /Cancelar pacote/ }));
		expect(screen.getByText(/7 sessões futuras/)).toBeInTheDocument();
	});
});
