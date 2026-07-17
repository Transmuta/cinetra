<script lang="ts">
	import type { Snippet } from 'svelte';
	import Logo from './Logo.svelte';
	import FlowArt from './cinetra/FlowArt.svelte';
	import '$lib/styles/cinetra.css';

	let {
		title,
		subtitle,
		children,
		footer
	}: {
		title: string;
		subtitle?: string;
		children: Snippet;
		footer?: Snippet;
	} = $props();
</script>

<!-- Auth em split (Cinetra Landing.dc.html): painel de marca navy à esquerda (some <900px)
     + painel de formulário papel à direita. -->
<div class="cn-root" style="min-height:100dvh;display:grid;grid-template-columns:1fr 1fr">
	<!-- painel de marca -->
	<div
		class="cn-brandpanel"
		style="position:relative;overflow:hidden;background:#212A37;color:#EAF0EE;padding:48px;display:flex;flex-direction:column;justify-content:space-between"
	>
		<div style="position:absolute;inset:0"><FlowArt k="auth" /></div>
		<div
			style="position:absolute;inset:0;background:linear-gradient(160deg,rgba(33,42,55,.6),rgba(33,42,55,.85));pointer-events:none"
		></div>
		<div style="position:relative;max-width:400px">
			<div
				style="font-family:'Martian Mono',monospace;font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#7FA59A;margin-bottom:18px"
			>
				A agenda da sua clínica
			</div>
			<div
				style="font-size:30px;line-height:1.3;font-weight:700;color:#fff;letter-spacing:-.02em;text-wrap:balance"
			>
				"Reduzimos as faltas em 40% no primeiro mês e a recepção parou de viver na planilha."
			</div>
			<div style="display:flex;align-items:center;gap:12px;margin-top:26px">
				<span
					style="width:44px;height:44px;border-radius:50%;background:#3A5A78;color:#fff;display:grid;place-items:center;font-weight:700"
					>ML</span
				>
				<div>
					<div style="font-weight:700;color:#fff">Dra. Marina Lopes</div>
					<div style="font-size:13px;color:#AEB8C0">Clínica Reabilitar · São Paulo</div>
				</div>
			</div>
		</div>
		<div style="position:relative;display:flex;gap:20px;font-size:13px;color:#8F99A2">
			<span>3&nbsp;mil+ profissionais</span><span>·</span><span>−40% de faltas</span><span>·</span
			><span>4,9/5</span>
		</div>
	</div>

	<!-- painel de formulário -->
	<div
		style="display:flex;flex-direction:column;padding:28px 28px 40px;overflow:auto;background:#F6F4EF"
	>
		<div
			style="flex:1;display:flex;flex-direction:column;justify-content:center;max-width:400px;width:100%;margin:0 auto;padding:32px 0"
		>
			<a href="/" style="margin-bottom:26px"><Logo class="h-6.5 w-auto" /></a>
			<div style="animation:cnFade .4s ease both">
				<h1 style="font-size:30px;font-weight:800;letter-spacing:-.02em;margin:0 0 8px">{title}</h1>
				{#if subtitle}
					<p style="font-size:15px;color:#736E63;margin:0 0 30px">{subtitle}</p>
				{/if}

				{@render children()}

				{#if footer}
					<p style="text-align:center;font-size:14px;color:#736E63;margin:26px 0 0">
						{@render footer()}
					</p>
				{/if}
			</div>
		</div>
	</div>
</div>
