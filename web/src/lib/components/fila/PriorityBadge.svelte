<script lang="ts">
	// A pílula de prioridade da fila (protótipo :2512/:2861): fundo na cor do nível, texto branco.
	// A cor é hex fixo (não token: a paleta de prioridade não muda no tema claro/escuro), então
	// vai por `style` inline — o mesmo motivo do quadrado de cor dos Tipos de atendimento.
	import { PRIORITY_META, type Priority } from '$lib/waitlist';
	import { avatarStyle } from '$lib/avatar';

	let { prio }: { prio: Priority } = $props();

	const meta = $derived(PRIORITY_META[prio]);
</script>

<span
	class="inline-block rounded-full px-[9px] py-0.5 text-[10.5px] font-bold"
	style={avatarStyle(meta.color)}
>{meta.label}</span>
