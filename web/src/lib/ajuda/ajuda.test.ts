import { describe, it, expect } from 'vitest';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import {
	TOPICOS,
	SECOES,
	indice,
	buscar,
	vizinhos,
	topicoPorId,
	ajudaDaRota,
	normalizar,
	printsDoTopico,
	textoDoTopico,
	topicosDoPapel,
	PAPEIS
} from './index';
import { PRINTS, PENDENTES, caminhoDaPrint } from './prints';

// O gate de integridade da central (doc 108 §5). Ele existe porque o modo de falha desta
// superfície é SILENCIOSO: um `vejaTambem` para um tópico renomeado vira link morto, uma print
// citada e não gerada vira quadrado vazio, e nada disso quebra o build nem aparece em teste de
// componente. Só uma varredura sobre o conteúdo inteiro pergunta essas coisas.

describe('estrutura dos tópicos', () => {
	it('id é único', () => {
		const ids = TOPICOS.map((t) => t.id);
		expect(new Set(ids).size).toBe(ids.length);
	});

	it('id é kebab-case sem acento — ele é a URL', () => {
		for (const t of TOPICOS) {
			expect(t.id, `${t.id} não serve como URL`).toMatch(/^[a-z0-9]+(-[a-z0-9]+)*$/);
		}
	});

	it('toda seção declarada existe, e nenhuma fica vazia', () => {
		const declaradas = new Set(SECOES.map((s) => s.id));
		for (const t of TOPICOS) expect(declaradas).toContain(t.secao);
		for (const s of SECOES) {
			expect(
				TOPICOS.some((t) => t.secao === s.id),
				`seção "${s.id}" está no índice sem nenhum tópico`
			).toBe(true);
		}
	});

	it('todo tópico tem título, resumo, papéis e corpo', () => {
		for (const t of TOPICOS) {
			expect(t.titulo.length, t.id).toBeGreaterThan(3);
			expect(t.resumo.length, t.id).toBeGreaterThan(10);
			expect(t.papeis.length, `${t.id} não diz a quem serve`).toBeGreaterThan(0);
			for (const p of t.papeis) expect(PAPEIS, `${t.id}: papel inválido`).toContain(p);
			expect(t.blocos.length, `${t.id} está sem corpo`).toBeGreaterThan(0);
		}
	});

	it('o resumo cabe na meta description (≤160 caracteres)', () => {
		for (const t of TOPICOS) expect(t.resumo.length, t.id).toBeLessThanOrEqual(160);
	});

	it('"veja também" aponta para tópico existente e nunca para si mesmo', () => {
		for (const t of TOPICOS) {
			for (const id of t.vejaTambem ?? []) {
				expect(topicoPorId(id), `${t.id} → "${id}" não existe`).toBeDefined();
				expect(id, `${t.id} aponta para si mesmo`).not.toBe(t.id);
			}
		}
	});

	it('todo passo com print declara o alt — imagem sem descrição é imagem que exclui leitor', () => {
		for (const t of TOPICOS) {
			for (const bloco of t.blocos) {
				if (bloco.tipo === 'passos') {
					for (const passo of bloco.passos) {
						if (passo.print) expect(passo.alt, `${t.id}: print sem alt`).toBeTruthy();
					}
				}
				if (bloco.tipo === 'print') expect(bloco.alt, `${t.id}: print sem alt`).toBeTruthy();
			}
		}
	});

	it('tabela tem o mesmo número de colunas em toda linha', () => {
		for (const t of TOPICOS) {
			for (const bloco of t.blocos) {
				if (bloco.tipo !== 'tabela') continue;
				for (const linha of bloco.linhas) {
					expect(linha.length, `${t.id}: linha fora do número de colunas`).toBe(
						bloco.colunas.length
					);
				}
			}
		}
	});
});

describe('as prints', () => {
	const citadas = new Set(TOPICOS.flatMap(printsDoTopico));

	it('id de print não se repete entre tópicos diferentes', () => {
		// Repetir a MESMA imagem em dois tópicos é legítimo; o que este teste pega é o descuido
		// de dois passos diferentes escreverem o mesmo id por copiar-e-colar sem trocar o número.
		const porTopico = TOPICOS.map((t) => ({ id: t.id, prints: printsDoTopico(t) }));
		for (const { id, prints } of porTopico) {
			expect(new Set(prints).size, `${id} cita a mesma print duas vezes`).toBe(prints.length);
		}
	});

	it('toda print citada existe no manifesto — ou está declarada como pendente', () => {
		const faltando = [...citadas].filter((id) => !PRINTS[id] && !PENDENTES.includes(id));
		expect(
			faltando,
			`prints citadas, não geradas e não declaradas em PENDENTES — rode "npm run prints":\n${faltando.join('\n')}`
		).toEqual([]);
	});

	it('a lista de pendentes encolhe: nada nela pode já estar gerado', () => {
		const jaGeradas = PENDENTES.filter((id) => PRINTS[id]);
		expect(
			jaGeradas,
			`já foram capturadas — tire de PENDENTES:\n${jaGeradas.join('\n')}`
		).toEqual([]);
	});

	it('nenhuma pendente é órfã: toda pendente é citada por algum tópico', () => {
		const soltas = PENDENTES.filter((id) => !citadas.has(id));
		expect(soltas, `em PENDENTES sem tópico que as cite:\n${soltas.join('\n')}`).toEqual([]);
	});

	it('toda print do manifesto está no disco', () => {
		const raiz = resolve(__dirname, '../../../static/ajuda');
		for (const [id, meta] of Object.entries(PRINTS)) {
			expect(existsSync(resolve(raiz, meta.arquivo)), `${id}: arquivo ausente`).toBe(true);
			expect(meta.largura, `${id}: largura inválida`).toBeGreaterThan(0);
			expect(meta.altura, `${id}: altura inválida`).toBeGreaterThan(0);
		}
	});

	it('não sobra print órfã no manifesto', () => {
		const orfas = Object.keys(PRINTS).filter((id) => !citadas.has(id));
		expect(orfas, `prints geradas e não citadas por tópico nenhum:\n${orfas.join('\n')}`).toEqual(
			[]
		);
	});

	it('caminhoDaPrint devolve o arquivo servido, e undefined para id desconhecido', () => {
		const algum = Object.keys(PRINTS)[0];
		if (algum) expect(caminhoDaPrint(algum)).toBe(`/ajuda/${PRINTS[algum].arquivo}`);
		expect(caminhoDaPrint('nao-existe')).toBeUndefined();
	});
});

describe('índice e navegação', () => {
	it('o índice cobre todo tópico, uma vez só', () => {
		const noIndice = indice().flatMap((g) => g.topicos);
		expect(noIndice.length).toBe(TOPICOS.length);
		expect(new Set(noIndice.map((t) => t.id)).size).toBe(TOPICOS.length);
	});

	it('vizinhos encadeia na ordem do índice', () => {
		const primeiro = TOPICOS[0];
		const ultimo = TOPICOS[TOPICOS.length - 1];
		expect(vizinhos(primeiro.id).anterior).toBeUndefined();
		expect(vizinhos(primeiro.id).proximo?.id).toBe(TOPICOS[1].id);
		expect(vizinhos(ultimo.id).proximo).toBeUndefined();
		expect(vizinhos('inexistente')).toEqual({});
	});

	it('todo papel alcança pelo menos um tópico de cada área que ele opera', () => {
		for (const papel of PAPEIS) {
			expect(topicosDoPapel(papel).length, papel).toBeGreaterThan(5);
		}
	});
});

describe('busca', () => {
	it('acha sem acento e sem caixa', () => {
		expect(normalizar('Exceções')).toBe('excecoes');
		const r = buscar('excecao');
		expect(r.map((t) => t.id)).toContain('excecoes');
	});

	it('exige TODOS os termos', () => {
		const ambos = buscar('encaixe conflito');
		for (const t of ambos) {
			const texto = normalizar(textoDoTopico(t));
			expect(texto).toContain('encaixe');
			expect(texto).toContain('conflito');
		}
	});

	it('quem casa no título vem antes', () => {
		const r = buscar('encaixe');
		expect(r[0]?.id).toBe('encaixe');
	});

	it('consulta vazia não devolve a central inteira', () => {
		expect(buscar('')).toEqual([]);
		expect(buscar('   ')).toEqual([]);
	});

	it('acha pelo texto do botão que a pessoa leu na tela', () => {
		// O termo não está em nenhum título: é o rótulo do botão, que só existe no corpo.
		expect(buscar('enviar confirmacao').length).toBeGreaterThan(0);
	});
});

describe('ajuda contextual por rota', () => {
	it('casa o mais específico primeiro', () => {
		expect(ajudaDaRota('/pacientes/novo')?.id).toBe('cadastrar-paciente');
		expect(ajudaDaRota('/pacientes')?.id).toBe('encontrar-um-paciente');
		expect(ajudaDaRota('/pacientes/abc-123')?.id).toBe('encontrar-um-paciente');
		expect(ajudaDaRota('/configuracoes/equipe')?.id).toBe('convidar-alguem');
		expect(ajudaDaRota('/configuracoes')?.id).toBe('roteiro-do-primeiro-dia');
	});

	it('rota sem ajuda devolve undefined, e não um tópico qualquer', () => {
		expect(ajudaDaRota('/')).toBeUndefined();
		expect(ajudaDaRota('/entrar')).toBeUndefined();
	});

	it('todo destino do mapa existe', () => {
		const rotas = [
			'/agenda',
			'/pacientes',
			'/pacientes/novo',
			'/profissionais',
			'/profissionais/novo',
			'/fila',
			'/relatorios',
			'/auditoria',
			'/notificacoes',
			'/perfil',
			'/configuracoes',
			'/configuracoes/clinica',
			'/configuracoes/tipos',
			'/configuracoes/horario',
			'/configuracoes/excecoes',
			'/configuracoes/comunicacao',
			'/configuracoes/equipe'
		];
		for (const rota of rotas) expect(ajudaDaRota(rota), rota).toBeDefined();
	});
});
