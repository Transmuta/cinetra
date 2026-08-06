<script lang="ts">
	import { initials } from '$lib/format';
	import { COR_DO_USUARIO_LOGADO, avatarStyle } from '$lib/avatar';

	// O avatar de uma **pessoa com conta**: a foto quando existe, as iniciais quando não.
	//
	// Um componente só porque os três lugares que o desenham — o botão do menu no topbar, o
	// cabeçalho de /perfil e cada linha da Equipe — tinham a mesma marcação repetida, e a foto
	// seria a próxima coisa a divergir entre elas, depois da cor e do contraste (ver `avatar.ts`).
	//
	// A URL vem do servidor **já assinada** e de vida curta (`ApiWeb.AvatarUrl`); aqui ela é só um
	// `src`. Sem foto, `avatarStyle` decide fundo E cor do texto juntos — é o que impede a metade
	// da cor de discordar da outra.
	//
	// `variant` existe porque as duas telas já discordavam **antes** da foto, e as duas estão
	// certas: no menu e no perfil o avatar é a própria pessoa (o slot de cor fixo,
	// `COR_DO_USUARIO_LOGADO`); na Equipe é gente que não é você, e ali ele é neutro para não
	// competir com o papel e o status, que são a informação daquela linha.
	//
	// A caixa das iniciais é `<span>`, não `<div>`: na Equipe ela mora dentro de um `<span>`, e
	// `div` ali seria aninhamento inválido. `display:grid` funciona igual nos dois.
	let {
		nome,
		url = null,
		variant = 'cor',
		class: klass = '',
		alt = null
	}: {
		nome: string;
		url?: string | null;
		variant?: 'cor' | 'neutro';
		class?: string;
		alt?: string | null;
	} = $props();

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
{:else if variant === 'neutro'}
	<span
		class="grid shrink-0 place-items-center rounded-full bg-surface-2 font-bold text-muted {klass}"
	>
		{iniciais}
	</span>
{:else}
	<span
		class="grid shrink-0 place-items-center rounded-full font-bold {klass}"
		style={avatarStyle(COR_DO_USUARIO_LOGADO)}
	>
		{iniciais}
	</span>
{/if}
