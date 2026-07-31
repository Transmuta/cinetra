<script lang="ts">
	import type { MemberStatus } from '$lib/members';

	let { status }: { status: MemberStatus } = $props();

	const pending = $derived(status === 'pendente');
</script>

<span
	class="inline-flex items-center gap-1.5 text-[11px] font-semibold {pending
		? 'text-warning'
		: 'text-muted'}"
>
	<span class="size-1.5 rounded-full {pending ? 'bg-warning-solid' : 'bg-accent'}"></span>
	{pending ? 'Convite pendente' : 'Ativo'}
</span>
