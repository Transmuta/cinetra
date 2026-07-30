import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { flushSync } from 'svelte';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));
vi.mock('$app/navigation', () => ({ invalidateAll: vi.fn() }));

import Page from './+page.svelte';
import { currentToast, dismissToast } from '$lib/toast.svelte';
import type { Patient } from '$lib/patients';

// O paciente do dia a dia: nome, telefone e convênio preenchidos, o resto em branco. Medido ao
// vivo no doc 56 — 20 dos 27 campos da ficha eram `—`, e a página reservava ~1.280px para eles.
function patient(over: Partial<Patient> = {}): Patient {
	return {
		id: 'pac1', nome: 'Mariana Alves', nome_social: null, cpf: '123.456.789-00', rg: null,
		genero: null, estado_civil: null, nascimento: '1990-05-14', responsavel: null,
		tel: '11999990000', email: null, cep: null, endereco: null, numero: null,
		complemento: null, bairro: null, cidade: null, uf: null, emergencia_nome: null,
		emergencia_parentesco: null, emergencia_tel: null, profissao: null, empresa: null,
		atend_tipo: 'convenio', convenio: 'Unimed', carteirinha: null, convenio_validade: null,
		medico: null, crm: null, como_conheceu: null, prefs: [], tags: [], lgpd: true,
		comunicacao: true, cor_indice: 1, ativo: true,
		...over
	} as Patient;
}

function data(over: Record<string, unknown> = {}) {
	return {
		patient: patient(),
		professionals: [],
		appointmentTypes: [],
		packages: [],
		history: [],
		historyMore: false,
		upcoming: [],
		upcomingMore: false,
		attachments: [],
		attachmentLimits: null,
		me: { papel: 'owner', timezone: 'America/Sao_Paulo' },
		...over
	} as never;
}

afterEach(cleanup);

describe('ficha do paciente — campo vazio (M1, doc 56)', () => {
	it('campo sem valor não ocupa espaço', () => {
		render(Page, { data: data(), form: null });

		expect(screen.getByText('Telefone / WhatsApp')).toBeInTheDocument();
		// e-mail em branco: nem o rótulo, nem o travessão
		expect(screen.queryByText('E-mail')).not.toBeInTheDocument();
		expect(screen.queryByText('CEP')).not.toBeInTheDocument();
	});

	it('cartão sem nenhum campo preenchido não é desenhado', () => {
		render(Page, { data: data(), form: null });
		// Emergência inteira em branco — 174px para três travessões, medidos ao vivo.
		expect(screen.queryByText('Contato de emergência')).not.toBeInTheDocument();
	});

	it('cartão com pelo menos um campo continua de pé', () => {
		render(Page, { data: data({ patient: patient({ emergencia_nome: 'João' }) }), form: null });
		expect(screen.getByText('Contato de emergência')).toBeInTheDocument();
		expect(screen.getByText('João')).toBeInTheDocument();
		// mas os irmãos vazios do mesmo cartão continuam fora
		expect(screen.queryByText('Parentesco')).not.toBeInTheDocument();
	});

	// Esconder campo vazio esconde também "falta preencher". O rodapé devolve isso em uma linha,
	// em vez de em 20 travessões.
	it('o que ficou de fora vira uma linha, com o caminho para completar', () => {
		render(Page, { data: data(), form: null });
		const link = screen.getByRole('link', { name: /não preenchidos/i });
		expect(link).toHaveAttribute('href', '/pacientes/pac1/editar');
	});

	it('ficha inteiramente preenchida não mostra o rodapé', () => {
		const cheio = patient({
			email: 'a@b.c', rg: '12.345.678-9', genero: 'Feminino', estado_civil: 'Solteira',
			responsavel: 'Ana', tel: '11999990000', cep: '01000-000', endereco: 'Rua A',
			numero: '10', complemento: null, bairro: 'Centro', cidade: 'São Paulo', uf: 'SP',
			emergencia_nome: 'João', emergencia_parentesco: 'Irmão', emergencia_tel: '11888880000',
			profissao: 'Designer', empresa: 'ACME', carteirinha: '123', convenio_validade: '2027-01-01',
			medico: 'Dr. X', crm: '12345', como_conheceu: 'Indicação', prefs: ['p1']
		});
		render(Page, {
			data: data({ patient: cheio, professionals: [{ id: 'p1', nome: 'Dra. X' }] }),
			form: null
		});
		// Por papel, não por texto: `queryByText(/não preenchidos/i)` deixava passar o singular
		// ("1 campo não preenchido") e o teste ficava verde com o rodapé na tela.
		expect(screen.queryByRole('link', { name: /preenchid/i })).not.toBeInTheDocument();
	});

	// Faltando UM campo, o rodapé fala no singular — e é aí que a asserção por texto plural
	// mentia. O teste existe para a concordância não voltar a esconder o rodapé de um teste.
	it('um campo só faltando conta no singular, e o rodapé continua lá', () => {
		const quaseCheio = patient({
			email: 'a@b.c', rg: '12.345.678-9', genero: 'Feminino', estado_civil: 'Solteira',
			responsavel: 'Ana', tel: '11999990000', cep: '01000-000', endereco: 'Rua A',
			numero: '10', bairro: 'Centro', cidade: 'São Paulo', uf: 'SP',
			emergencia_nome: 'João', emergencia_parentesco: 'Irmão', emergencia_tel: '11888880000',
			profissao: 'Designer', empresa: 'ACME', carteirinha: '123', convenio_validade: '2027-01-01',
			medico: 'Dr. X', crm: '12345', como_conheceu: 'Indicação'
			// `prefs` fica vazio: é o único campo que falta
		});
		render(Page, { data: data({ patient: quaseCheio }), form: null });
		expect(screen.getByRole('link', { name: /1 campo não preenchido/i })).toBeInTheDocument();
	});

	// O rodapé leva a `/editar`, que é owner·admin. Oferecer o caminho a quem leva 403 é pior que
	// não oferecer — a mesma regra que já governa "Editar dados" e a seção de anexos.
	it('quem não pode editar não vê o convite para completar', () => {
		render(Page, { data: data({ me: { papel: 'profissional' } }), form: null });
		expect(screen.queryByRole('link', { name: /preenchid/i })).not.toBeInTheDocument();
	});
});

// M4. A hipótese era recolher o cadastro inteiro; a medição do M1 a derrubou — o que inchava a
// página era campo VAZIO, não campo preenchido. Sobrou o recorte que a medição sustenta: os dois
// cartões de baixa frequência saem da rolagem, e o que se pergunta ao telefone continua aberto.
describe('ficha do paciente — o que se consulta e o que se confere (M4, doc 56)', () => {
	const cheio = () =>
		patient({
			email: 'a@b.c', rg: '12.345.678-9', genero: 'Feminino', estado_civil: 'Casada',
			responsavel: 'Carlos', profissao: 'Arquiteta', empresa: 'ACME',
			como_conheceu: 'Indicação', carteirinha: '123', medico: 'Dr. X'
		});

	it('telefone, convênio e emergência ficam abertos', () => {
		render(Page, {
			data: data({ patient: patient({ emergencia_nome: 'João' }) }),
			form: null
		});

		for (const titulo of ['Contato', 'Atendimento & convênio', 'Contato de emergência']) {
			expect(screen.getByText(titulo).closest('details')).toBeNull();
		}
	});

	it('identificação e perfil ficam recolhidos, mas presentes', () => {
		render(Page, { data: data({ patient: cheio() }), form: null });

		for (const titulo of ['Identificação', 'Perfil']) {
			const bloco = screen.getByText(titulo).closest('details');
			expect(bloco).not.toBeNull();
			expect(bloco).not.toHaveAttribute('open');
		}
		// recolhido não é ausente: o dado continua no DOM, alcançável por teclado e por busca
		expect(screen.getByText('12.345.678-9')).toBeInTheDocument();
		expect(screen.getByText('Arquiteta')).toBeInTheDocument();
	});

	// "Responsável legal" saiu de Identificação para Contato: paciente menor de idade é caso de
	// atendimento, não de conferência cadastral — não pode ficar atrás de um clique.
	it('responsável legal fica com o contato, aberto', () => {
		render(Page, { data: data({ patient: cheio() }), form: null });
		expect(screen.getByText('Responsável legal').closest('details')).toBeNull();
	});

	it('cartão recolhível sem nenhum campo preenchido some, como os outros', () => {
		render(Page, { data: data(), form: null });
		expect(screen.queryByText('Perfil')).not.toBeInTheDocument();
	});
});

describe('ficha do paciente — o repetido (M2, doc 56)', () => {
	it('idade aparece uma vez só (é stat do cabeçalho)', () => {
		render(Page, { data: data(), form: null });
		expect(screen.getAllByText(/^Idade$/i)).toHaveLength(1);
	});

	// "Tipo de atendimento: Unimed" e "Convênio: Unimed" eram células vizinhas com o MESMO texto,
	// e o chip do cabeçalho dizia a mesma coisa uma terceira vez.
	it('tipo de atendimento não se repete ao lado do convênio', () => {
		render(Page, { data: data(), form: null });
		expect(screen.queryByText('Tipo de atendimento')).not.toBeInTheDocument();
		expect(screen.getByText('Convênio')).toBeInTheDocument();
	});

	it('consentimentos ficam no cabeçalho, não num cartão de 216px', () => {
		render(Page, { data: data(), form: null });
		expect(screen.queryByText('Consentimentos')).not.toBeInTheDocument();
		// os dois fatos continuam na tela
		expect(screen.getByText('Consentimento LGPD')).toBeInTheDocument();
		expect(screen.getByText(/contato autorizado/i)).toBeInTheDocument();
	});
});

// A ficha ligava `form.error` a UM lugar só — o modal da grade do pacote — e ele só existe
// enquanto está aberto. Então arquivar o paciente, ou o 422 do arquivar-pacote ("ainda há sessão
// futura", que o próprio servidor documenta como "o erro vai para a tela"), sumiam: o botão
// parava de girar e nada mais acontecia.
describe('ficha do paciente — falha de action', () => {
	beforeEach(() => dismissToast());

	it('erro do arquivar o PACIENTE vira toast de erro', () => {
		render(Page, {
			data: data(),
			form: { action: 'deactivate', error: 'Você não tem permissão para esta ação.' } as never
		});
		flushSync();

		expect(currentToast()?.message).toBe('Você não tem permissão para esta ação.');
		expect(currentToast()?.variant).toBe('error');
	});

	it('erro do arquivar o PACOTE vira toast de erro', () => {
		render(Page, {
			data: data(),
			form: { action: 'archivePackage', error: 'Ainda há sessão futura neste pacote.' } as never
		});
		flushSync();

		expect(currentToast()?.message).toBe('Ainda há sessão futura neste pacote.');
	});

	it('falha sem mensagem cai na genérica — nunca em silêncio', () => {
		render(Page, { data: data(), form: { action: 'pausePackage' } as never });
		flushSync();

		expect(currentToast()?.message).toBe('Não foi possível concluir a ação.');
	});

	// A exceção deliberada: a grade tem modal aberto, e o erro mora DENTRO dele (com o que a
	// pessoa preencheu à vista). Um toast em cima seria a mesma frase duas vezes.
	it('erro da GRADE não vira toast — ele fica dentro do modal', () => {
		render(Page, {
			data: data(),
			form: { action: 'grade', error: 'Escolha o profissional, os dias e o horário.' } as never
		});
		flushSync();

		expect(currentToast()).toBeNull();
	});

	it('sucesso não vira toast de erro', () => {
		render(Page, { data: data(), form: { ok: true, action: 'deactivate' } as never });
		flushSync();

		expect(currentToast()).toBeNull();
	});
});
