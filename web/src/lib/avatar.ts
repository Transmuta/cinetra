// Paleta categórica dos avatares da agenda (Cinetra). Índice 1-based; o protótipo faz
// `(ci-1) % 7` (`profColor` :315 / `patientColor` :316). É um **token de design compartilhado**
// entre profissional e paciente — mora aqui, num módulo neutro, para não duplicar a lista nem
// acoplar os dois domínios (`patients.ts` ↔ `professionals.ts`). NÃO é a paleta de Tipos de
// atendimento, que tem 8 cores e validação própria (`appointment-types.ts`).
export const AVATAR_PALETTE = ['#0FB5A6', '#0072B2', '#009E73', '#CC79A7', '#7A52CC', '#D55E00', '#E69F00'];

// Cor do avatar para um índice 1-based, com wrap (tolera 0/negativos como o protótipo).
export function avatarColor(corIndice: number): string {
	const n = AVATAR_PALETTE.length;
	return AVATAR_PALETTE[(((corIndice - 1) % n) + n) % n];
}
