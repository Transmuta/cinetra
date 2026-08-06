<script lang="ts">
	// O layout não desenha casca: quem monta a `AjudaShell` é cada página, porque o herói dela
	// carrega título, subtítulo e descrição do que está aberto — e um layout não sabe disso. O que
	// vive aqui é só o dado compartilhado (`logado`), que o `+layout.server.ts` resolve uma vez.
	let { children }: { children: import('svelte').Snippet } = $props();
</script>

{@render children()}
