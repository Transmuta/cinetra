<script lang="ts">
	import Crown from '@lucide/svelte/icons/crown';
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import User from '@lucide/svelte/icons/user';
	import Badge from '$lib/components/Badge.svelte';
	import { ROLE_META } from '$lib/members';
	import type { Papel } from '$lib/session';

	let { papel }: { papel: Papel } = $props();

	const ICONS: Record<Papel, typeof Crown> = {
		owner: Crown,
		admin: ShieldCheck,
		profissional: Stethoscope,
		recepcao: User
	};

	// O papel decide o TOM; a geometria é a do `Badge`, comum a toda pílula do app. O
	// `profissional` sai do azul e vai para o tom `info` — era a única das quatro que misturava
	// uma superfície neutra com uma cor semântica de texto.
	const TOM = {
		owner: 'accent',
		admin: 'accent',
		profissional: 'info',
		recepcao: 'neutro'
	} as const;

	const Icon = $derived(ICONS[papel]);
</script>

<Badge tone={TOM[papel]}>
	<Icon size={12} />
	{ROLE_META[papel].label}
</Badge>
