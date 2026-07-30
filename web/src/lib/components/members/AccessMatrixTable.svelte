<script lang="ts">
	// A matriz "o que cada papel pode" (AN-06 / D-H7), exibida em Configurações › Equipe —
	// a consulta acontece na hora de convidar, que é quando a pergunta existe. O conteúdo vem
	// do backend (perto das policies, com tripwire); aqui é só a tabela.
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import { ROLE_META } from '$lib/members';
	import { NIVEL_META, type AccessMatrixData } from '$lib/access-matrix';

	let { matrix }: { matrix: AccessMatrixData } = $props();

	// Cada tom em fundo + texto (nunca só cor): o rótulo escrito é o dado, o tom é reforço.
	const TONE_CLASS = {
		ok: 'bg-teal-subtle text-teal-text',
		meio: 'bg-surface-2 text-muted',
		nada: 'text-faint'
	} as const;
</script>

<!-- `mt-3`: o ritmo da página (a seção de membros usa `mb-3`, mas a vizinha de cima daqui —
     "Profissionais sem acesso" — é condicional e não tem margem inferior). -->
<section class="mt-3 rounded-lg border border-edge bg-surface p-4">
	<div class="mb-1 flex items-center gap-2">
		<ShieldCheck size={15} class="text-faint" />
		<h2 class="text-[14px] font-semibold">O que cada papel pode</h2>
	</div>
	<p class="mb-3 text-[12.5px] text-muted">
		Resumo das permissões por papel — o mesmo que o sistema aplica. Consulte na hora de convidar.
	</p>

	<div class="overflow-x-auto">
		<table class="w-full min-w-[560px] border-collapse text-[12.5px]">
			<thead>
				<tr class="border-b border-edge text-left">
					<th scope="col" class="py-2 pr-3 font-semibold text-muted">Área</th>
					{#each matrix.papeis as papel (papel)}
						<th scope="col" class="px-2 py-2 font-semibold text-muted">{ROLE_META[papel].label}</th>
					{/each}
				</tr>
			</thead>
			<tbody>
				{#each matrix.areas as area (area.id)}
					<tr class="border-b border-edge/60 align-top">
						<th scope="row" class="py-2 pr-3 text-left font-medium text-ink">
							{area.label}
							{#if area.obs}
								<span class="mt-0.5 block text-[11px] font-normal text-faint">{area.obs}</span>
							{/if}
						</th>
						{#each matrix.papeis as papel (papel)}
							{@const meta = NIVEL_META[area.acesso[papel]]}
							<td class="px-2 py-2">
								<span class="inline-block rounded px-1.5 py-0.5 text-[11.5px] font-semibold {TONE_CLASS[meta.tone]}">
									{meta.label}
								</span>
							</td>
						{/each}
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
</section>
