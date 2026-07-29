<script lang="ts">
	import { enhance } from '$app/forms';
	import { page } from '$app/state';
	import { MailCheck, LoaderCircle, ArrowLeft } from '@lucide/svelte';
	import GoogleIcon from './GoogleIcon.svelte';

	let {
		form = null,
		submitLabel,
		googleLabel,
		googleHref = '/auth/google',
		collectName = false,
		aceite = false
	}: {
		form?: { sent?: boolean; email?: string; nome?: string; error?: string } | null;
		submitLabel: string;
		googleLabel: string;
		googleHref?: string;
		// Cadastro por magic link coleta o nome; login (/entrar) não.
		collectName?: boolean;
		// Nota de aceite dos documentos legais: só a tela que CRIA conta a mostra.
		aceite?: boolean;
	} = $props();

	let submitting = $state(false);
	// Google é navegação completa (reload) com um round-trip até a API montar a URL do Google;
	// marcamos o carregamento no clique para dar feedback até o browser sair da página.
	let googleLoading = $state(false);
	// "Usar outro e-mail" volta à própria rota (SPA nav com JS, reload sem JS) — limpa `form`.
	const resetHref = $derived(page.url.pathname);

	// Estilos do protótipo (Cinetra Landing.dc.html) — paleta papel/navy, fora do teal do app.
	const labelStyle = 'display:block;font-size:13px;font-weight:600;color:#3D454F;margin-bottom:7px';
	const inputStyle =
		'width:100%;padding:12px 14px;border:1px solid #D9D4C7;border-radius:11px;font-size:15px;background:#fff;color:#212A37';
	const primaryStyle =
		'width:100%;background:#212A37;border:none;color:#fff;font-size:15px;font-weight:700;padding:13px;border-radius:11px;cursor:pointer';
</script>

{#if form?.sent}
	<!-- Estado neutro (Cinetra Landing.dc.html · isSent): não revela se o e-mail existe (ADR-015). -->
	<div style="animation:cnFade .4s ease both;text-align:center">
		<span
			style="width:60px;height:60px;border-radius:16px;background:rgba(127,165,154,.16);color:#4E7468;display:grid;place-items:center;margin:0 auto 24px"
		>
			<MailCheck size={30} />
		</span>
		<h1 style="font-size:28px;font-weight:800;letter-spacing:-.02em;margin:0 0 10px">
			Verifique seu e-mail
		</h1>
		<p style="font-size:15px;color:#736E63;margin:0 0 30px;line-height:1.55">
			Se <strong style="color:#212A37">{form.email}</strong> tiver uma conta, enviamos um link de
			acesso. Abra a mensagem para entrar — o link expira em breve.
		</p>
		<a
			href={resetHref}
			class="cn-hover-dark"
			style="width:100%;display:inline-flex;align-items:center;justify-content:center;gap:8px;box-sizing:border-box;{primaryStyle}"
		>
			<ArrowLeft size={16} /> Usar outro e-mail
		</a>
	</div>
{:else}
	<!-- Progressive enhancement: com JS, envia sem reload e mostra o estado inline; sem JS,
	     submit nativo cai na mesma action e o estado vem por SSR. -->
	<form
		method="POST"
		style="display:flex;flex-direction:column;gap:16px"
		use:enhance={() => {
			submitting = true;
			return async ({ update }) => {
				await update({ reset: false });
				submitting = false;
			};
		}}
	>
		{#if collectName}
			<label style="display:block">
				<span style={labelStyle}>Nome</span>
				<input
					name="nome"
					type="text"
					value={form?.nome ?? ''}
					placeholder="Seu nome"
					required
					autocomplete="name"
					maxlength={160}
					style={inputStyle}
				/>
			</label>
		{/if}

		<label style="display:block">
			<span style={labelStyle}>E-mail</span>
			<input
				name="email"
				type="email"
				value={form?.email ?? ''}
				placeholder="voce@clinica.com.br"
				required
				autocomplete="email"
				style={inputStyle}
			/>
		</label>

		{#if form?.error}
			<p style="font-size:13px;color:#C0392B;margin:0">{form.error}</p>
		{/if}

		<button
			type="submit"
			disabled={submitting}
			class="cn-hover-dark"
			style="{primaryStyle};margin-top:2px;{submitting ? 'opacity:.65;cursor:not-allowed' : ''}"
		>
			{submitting ? 'Enviando…' : submitLabel}
		</button>
	</form>

	<div
		style="display:flex;align-items:center;gap:14px;margin:22px 0;color:#696456;font-size:13px"
	>
		<span style="flex:1;height:1px;background:#E6E2D8"></span>ou<span
			style="flex:1;height:1px;background:#E6E2D8"
		></span>
	</div>

	<!-- reload: /auth/google é endpoint +server (sem +page); sem navegação completa o client
	     router do SvelteKit 404a. loading: feedback enquanto o browser navega ao Google. -->
	<a
		href={googleHref}
		data-sveltekit-reload
		aria-busy={googleLoading ? 'true' : undefined}
		onclick={() => (googleLoading = true)}
		class="cn-hover-border"
		style="width:100%;display:flex;align-items:center;justify-content:center;gap:10px;box-sizing:border-box;background:#fff;border:1px solid #D9D4C7;color:#212A37;font-size:15px;font-weight:600;padding:12px;border-radius:11px;cursor:pointer;{googleLoading
			? 'pointer-events:none;opacity:.7'
			: ''}"
	>
		{#if googleLoading}
			<LoaderCircle size={16} class="animate-spin" /> Conectando…
		{:else}
			<GoogleIcon /> {googleLabel}
		{/if}
	</a>

	{#if aceite}
		<!-- Aceite dos documentos legais (decisão de 2026-07-29): NOTA, não caixa de seleção.
		     O cadastro tem dois caminhos e o do Google sai da página por um `<a>` de navegação
		     completa; uma caixa obrigatória travaria só o formulário, e sem JavaScript nem isso.
		     Por ficar DEPOIS dos dois botões, a nota cobre os dois, que é o que o aceite precisa
		     cobrir. -->
		<!-- `#736E63` (o mesmo cinza do subtítulo do card) e não um tom mais claro: a varredura axe
		     reprovou #8C8678 aqui com 3,29:1, abaixo do mínimo de 4,5:1 da WCAG AA para texto
		     pequeno. Nota legal ilegível é pior que nota legal ausente. -->
		<p
			data-testid="aceite"
			style="font-size:13px;line-height:1.55;color:#736E63;margin:18px 0 0;text-align:center"
		>
			Ao criar sua conta, por e-mail ou com o Google, você concorda com os
			<a href="/termos" style="color:#4E7468;font-weight:600;text-decoration:underline;text-underline-offset:2px"
				>Termos de Uso</a
			>
			e a
			<a
				href="/privacidade"
				style="color:#4E7468;font-weight:600;text-decoration:underline;text-underline-offset:2px"
				>Política de Privacidade</a
			>.
		</p>
	{/if}
{/if}
