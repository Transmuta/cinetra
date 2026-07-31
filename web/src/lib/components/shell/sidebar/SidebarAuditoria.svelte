<script lang="ts">
	// Auditoria (doc 25 §11.4). Os quatro eixos que a API sempre aceitou e a tela nunca expôs:
	// registro, período, ação e autor. Três deles ficavam implementados no controller, no BFF e no
	// load, e **nenhum controle os escrevia** — filtro morto.
	//
	// Como nas outras seções, tudo viaja na URL e tudo é `<a>`: o estado é linkável, o botão
	// voltar funciona e o load busca já filtrado.
	import { page } from '$app/state';
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import CalendarRange from '@lucide/svelte/icons/calendar-range';
	import Users from '@lucide/svelte/icons/users';
	import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
	import Clock4 from '@lucide/svelte/icons/clock-4';
	import ScrollText from '@lucide/svelte/icons/scroll-text';
	import User from '@lucide/svelte/icons/user';
	import { initials } from '$lib/format';
	import { avatarStyle } from '$lib/avatar';
	import {
		actionOptions,
		RESOURCE_GROUPS,
		auditHref,
		canViewAudit,
		parseAction,
		parsePeriod,
		parseResource,
		resourcePatch,
		PERIOD_OPTIONS,
		type AuditRef
	} from '$lib/audit';
	import type { Papel } from '$lib/session';

	const dados = $derived(page.data as { autores?: AuditRef[]; me?: { papel?: Papel | null } });

	// O mesmo predicado que o rail usa para esconder o destino. Sem ele, a sidebar contextual
	// aparecia na página de **403**: quem decide o ramo é o CAMINHO, e ele continua `/auditoria`
	// quando o load falha — então a única seção owner·admin do app era também a única cuja barra
	// de filtros a recepção via, com cada clique levando a outro 403.
	const canAudit = $derived(canViewAudit(dados.me?.papel));
	const audResource = $derived(parseResource(page.url.searchParams.get('resource')));
	const audAction = $derived(parseAction(page.url.searchParams.get('acao'), audResource));
	const audPeriod = $derived(parsePeriod(page.url.searchParams.get('periodo')));
	const audAutor = $derived(page.url.searchParams.get('autor'));
	// Os autores vêm do load (a equipe da clínica), como `professionals` em Relatórios.
	const audAutores = $derived(dados.autores ?? []);
	const audActions = $derived(actionOptions(audResource));

	// Trocar de grupo zera ação e registro junto (ver `resourcePatch`): os vocabulários de ação não
	// se cruzam entre grupos, e um filtro órfão devolveria um feed legitimamente vazio.
	const audHref = (patch: Record<string, string | null>) =>
		auditHref(page.url.searchParams, { ...patch, page: null });
</script>

{#if canAudit}
		<div class="flex-1 overflow-auto px-3 py-1">
			<!-- Uma linha de filtro. Snippet porque são quatro listas com a mesma anatomia (ícone
			     opcional, rótulo, ativo) — escrever a classe quatro vezes é como os `py-[7px]`
			     divergiram entre seções. -->
			{#snippet filtro(href: string, label: string, isActive: boolean, Icon: typeof CalendarDays | null)}
				<a
					{href}
					aria-current={isActive ? 'page' : undefined}
					class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {isActive
						? 'bg-surface-2 font-semibold text-ink'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					{#if Icon}
						<span class={isActive ? 'text-accent-text' : 'text-faint'}><Icon size={15} /></span>
					{:else}
						<span class="grid size-[15px] place-items-center">
							<span
								class="size-1.5 rounded-full {isActive ? 'bg-accent' : 'bg-edge-strong'}"
							></span>
						</span>
					{/if}
					<span class="flex-1 truncate">{label}</span>
				</a>
			{/snippet}
	
			<!-- Ordem dos eixos: PERÍODO e AUTOR primeiro. "quando" e "quem" são as duas perguntas
			     com que se chega na trilha ("o que houve esta semana", "o que fulano fez"); o
			     recorte por registro e por ação é refinamento de quem já está olhando. -->
			<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
				Período
			</div>
			{#each PERIOD_OPTIONS as per (per.key)}
				{@render filtro(
					audHref({ periodo: per.key === 'tudo' ? null : per.key }),
					per.label,
					audPeriod === per.key,
					per.key === 'tudo' ? Clock4 : CalendarRange
				)}
			{/each}
	
			{#if audAutores.length}
				<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
					Autor
				</div>
				{@render filtro(audHref({ autor: null }), 'Todos', !audAutor, Users)}
				{#each audAutores as autor (autor.id)}
					{@render filtro(audHref({ autor: autor.id }), autor.nome, audAutor === autor.id, User)}
				{/each}
			{/if}
	
			<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
				Registro
			</div>
			<!-- "Tudo" é o DEFAULT e vem primeiro: com doze recursos auditados, a pergunta que o
			     admin faz é "o que aconteceu na clínica" — o recorte por grupo é a exceção, não a
			     porta de entrada. Era o contrário enquanto a trilha tinha dois recursos e cada um
			     era uma tabela própria (doc 63). -->
			{@render filtro(
				auditHref(page.url.searchParams, resourcePatch(null)),
				'Tudo',
				!audResource,
				ScrollText
			)}
			{#each RESOURCE_GROUPS as r (r.key)}
				{@render filtro(
					auditHref(page.url.searchParams, resourcePatch(r.key)),
					r.label,
					audResource === r.key,
					null
				)}
			{/each}
	
			<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
				Ação
			</div>
			{@render filtro(audHref({ acao: null }), 'Todas', !audAction, SlidersHorizontal)}
			{#each audActions as opt (opt.key)}
				{@render filtro(audHref({ acao: opt.key }), opt.label, audAction === opt.key, null)}
			{/each}
		</div>{/if}
