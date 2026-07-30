<script lang="ts">
	import Crown from '@lucide/svelte/icons/crown';
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import User from '@lucide/svelte/icons/user';
	import { ROLE_META } from '$lib/members';
	import type { Papel } from '$lib/session';

	let { papel }: { papel: Papel } = $props();

	const ICONS: Record<Papel, typeof Crown> = {
		owner: Crown,
		admin: ShieldCheck,
		profissional: Stethoscope,
		recepcao: User
	};

	const STYLE: Record<Papel, string> = {
		owner: 'bg-teal-subtle text-teal-text',
		admin: 'bg-teal-subtle text-teal-text',
		profissional: 'bg-surface-2 text-info',
		recepcao: 'bg-surface-2 text-muted'
	};

	const Icon = $derived(ICONS[papel]);
</script>

<span
	class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-[3px] text-[11.5px] font-semibold {STYLE[
		papel
	]}"
>
	<Icon size={12} />
	{ROLE_META[papel].label}
</span>
