// A matriz de acesso por papel (AN-06 / D-H7). O CONTEÚDO vem do backend
// (`GET /api/access-matrix` ← `Api.Accounts.AccessMatrix`, com tripwire contra as policies);
// aqui moram só os tipos e o vocabulário visual dos níveis. Os rótulos dos papéis são os de
// `ROLE_META` ($lib/members) — fonte única, como manda o D-H7.

export type Nivel = 'total' | 'leitura' | 'propria' | 'nao';

export type PapelColuna = 'owner' | 'admin' | 'profissional' | 'recepcao';

export interface MatrixArea {
	id: string;
	label: string;
	obs: string | null;
	acesso: Record<PapelColuna, Nivel>;
}

export interface AccessMatrixData {
	papeis: PapelColuna[];
	areas: MatrixArea[];
}

/** Rótulo e tom de cada célula. `tone` é token do tema — a célula nunca é só cor (a11y). */
export const NIVEL_META: Record<Nivel, { label: string; tone: 'ok' | 'meio' | 'nada' }> = {
	total: { label: 'Vê e altera', tone: 'ok' },
	leitura: { label: 'Só vê', tone: 'meio' },
	propria: { label: 'Só o próprio', tone: 'meio' },
	nao: { label: 'Sem acesso', tone: 'nada' }
};
