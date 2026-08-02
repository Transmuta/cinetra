<script lang="ts">
	import { initials } from '$lib/format';
	import { COR_DO_USUARIO_LOGADO, avatarStyle } from '$lib/avatar';

	// O avatar do usuário logado: a **foto** quando existe, as iniciais quando não.
	//
	// Um componente só porque os dois lugares que o desenham (o botão do menu, no topbar, e o
	// cabeçalho de /perfil) tinham a mesma marcação escrita duas vezes — e a foto seria a terceira
	// coisa a divergir entre elas, depois da cor e do contraste (ver `avatar.ts`).
	//
	// A URL vem do `/me` **já assinada** e de vida curta (a API a emite a cada carga do layout);
	// aqui ela é só um `src`. Sem foto, `avatarStyle` decide fundo E cor do texto juntos — é o
	// que impede a metade da cor de discordar da outra.
	let {
		nome,
		url = null,
		class: klass = '',
		alt = null
	}: { nome: string; url?: string | null; class?: string; alt?: string | null } = $props();

	const iniciais = $derived(initials(nome));
</script>

{#if url}
	<!-- `alt=""` quando o avatar é decorativo (o nome já está escrito ao lado, e o botão do menu
	     tem `title`/`aria-*` próprios): leitor de tela não deve anunciar a mesma pessoa duas vezes.
	     `object-cover` porque a foto do Google é quadrada, mas o recorte é redondo. -->
	<img
		src={url}
		alt={alt ?? ''}
		class="shrink-0 rounded-full object-cover {klass}"
		referrerpolicy="no-referrer"
	/>
{:else}
	<div
		class="grid shrink-0 place-items-center rounded-full font-bold {klass}"
		style={avatarStyle(COR_DO_USUARIO_LOGADO)}
	>
		{iniciais}
	</div>
{/if}
