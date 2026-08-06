<script lang="ts">
	// Os três avisos da central (doc 108). São três tons porque são três coisas diferentes, e
	// misturá-las custa caro para quem lê com pressa:
	//
	//  - `papel`   — restrição do sistema: a pessoa NÃO vai conseguir, e precisa saber antes de
	//                tentar. É o que responde "por que não vejo esse botão".
	//  - `atencao` — consequência difícil de desfazer.
	//  - `dica`    — atalho; pode ser ignorado sem prejuízo.
	//
	// Cada tom traz **ícone e palavra**, nunca só cor: a distinção precisa sobreviver ao daltonismo
	// e à impressão em preto e branco (a central é impressa em clínica, é o material de treino).
	//
	// Cor em hex, da paleta da marca — e não dos tokens do app. A central é papel/navy fixo, sem
	// tema escuro; com `--color-info` e `text-ink` a caixa trocava de cor com o tema do aparelho e
	// o texto sumia sobre o creme. Ver a nota em `Busca.svelte` e a isenção em `cor-crua.test.ts`.
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Lightbulb from '@lucide/svelte/icons/lightbulb';
	import type { Tom } from '$lib/ajuda/tipos';

	let { tom, texto }: { tom: Tom; texto: string } = $props();

	const META = {
		papel: {
			rotulo: 'Quem pode',
			Icon: ShieldCheck,
			fundo: '#EDF2F7',
			borda: '#C3D4E2',
			icone: '#3E6288'
		},
		atencao: {
			rotulo: 'Atenção',
			Icon: TriangleAlert,
			fundo: '#FBF1E3',
			borda: '#E8CFA6',
			icone: '#9A6A05'
		},
		dica: {
			rotulo: 'Dica',
			Icon: Lightbulb,
			fundo: '#EBF4F2',
			borda: '#9CC9BC',
			icone: '#3F6357'
		}
	} as const;

	const info = $derived(META[tom]);
</script>

<aside
	style="display:flex;gap:11px;margin:20px 0;padding:13px 15px;border:1px solid {info.borda};border-radius:12px;background:{info.fundo}"
>
	<span style="flex-shrink:0;margin-top:2px;color:{info.icone}"><info.Icon size={16} /></span>
	<p style="margin:0;font-size:15.5px;line-height:1.6;color:#3D454F">
		<strong style="color:#212A37;font-weight:700">{info.rotulo}:</strong>
		{texto}
	</p>
</aside>
