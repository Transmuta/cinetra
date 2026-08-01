<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { CONTROL_CLASS, CONTROL_PX, CONTROL_H } from '$lib/components/Field.svelte';
	import AddressFields from '$lib/components/AddressFields.svelte';
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { envio } from '$lib/forms.svelte';
	import Circle from '@lucide/svelte/icons/circle';
	import Info from '@lucide/svelte/icons/info';
	import { maskCnpj, normalizeCnpj, isValidCnpj } from '$lib/cnpj';
	import { maskTel } from '$lib/masks';
	import { canManageClinic } from '$lib/session';
	import { toast } from '$lib/toast.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// Todo membro lê; só owner/admin edita (a policy da API é a autoridade — aqui é UX).
	const canManage = $derived(canManageClinic(data.me.papel));

	// Rascunho local: edita e só então salva (como Horário/Tipos). Reidratado do `data` após salvar.
	//
	// Um objeto só, e não uma variável por campo: o `AddressFields` escreve em quatro deles de uma
	// vez quando o CEP responde, e precisa do mesmo proxy `$state` dos dois lados.
	let f = $state(
		untrack(() => ({
			nome: data.clinic.nome,
			cnpj: maskCnpj(data.clinic.cnpj ?? ''),
			telefone: data.clinic.telefone ?? '',
			cep: data.clinic.cep ?? '',
			endereco: data.clinic.endereco ?? '',
			numero: data.clinic.numero ?? '',
			complemento: data.clinic.complemento ?? '',
			bairro: data.clinic.bairro ?? '',
			cidade: data.clinic.cidade ?? '',
			uf: data.clinic.uf ?? ''
		}))
	);

	// CNPJ é opcional; quando preenchido, precisa ser válido (espelho do `Api.Cnpj` — a API confirma).
	const cnpjInvalido = $derived(f.cnpj.trim() !== '' && !isValidCnpj(f.cnpj));

	// Apagar o telefone com o WhatsApp ligado é 422 na API (`WhatsappExigeTelefone`). Avisar aqui
	// evita o toast de erro depois de a pessoa já ter apagado e clicado em Salvar — e explica a
	// causa, que mora numa TELA VIZINHA e não seria adivinhável a partir daqui.
	const telefoneApagado = $derived(data.clinic.msg_whatsapp_ativo && f.telefone.trim() === '');

	const dirty = $derived(
		f.nome.trim() !== data.clinic.nome ||
			normalizeCnpj(f.cnpj) !== (data.clinic.cnpj ?? '') ||
			f.telefone.trim() !== (data.clinic.telefone ?? '') ||
			f.cep.trim() !== (data.clinic.cep ?? '') ||
			f.endereco.trim() !== (data.clinic.endereco ?? '') ||
			f.numero.trim() !== (data.clinic.numero ?? '') ||
			f.complemento.trim() !== (data.clinic.complemento ?? '') ||
			f.bairro.trim() !== (data.clinic.bairro ?? '') ||
			f.cidade.trim() !== (data.clinic.cidade ?? '') ||
			f.uf.trim() !== (data.clinic.uf ?? '')
	);

	const podeSalvar = $derived(dirty && f.nome.trim() !== '' && !cnpjInvalido && !telefoneApagado);

	function sync() {
		f.nome = data.clinic.nome;
		f.cnpj = maskCnpj(data.clinic.cnpj ?? '');
		f.telefone = data.clinic.telefone ?? '';
		f.cep = data.clinic.cep ?? '';
		f.endereco = data.clinic.endereco ?? '';
		f.numero = data.clinic.numero ?? '';
		f.complemento = data.clinic.complemento ?? '';
		f.bairro = data.clinic.bairro ?? '';
		f.cidade = data.clinic.cidade ?? '';
		f.uf = data.clinic.uf ?? '';
	}

	const save = envio({
		reset: false,
		aoResponder: (result) => {
			if (result.type === 'success') {
				sync();
				toast('Dados da clínica salvos');
			} else if (result.type === 'failure') {
				const message = result.data?.error;
				toast(typeof message === 'string' ? message : 'Não foi possível salvar.', 'error');
			}
		}
	});

	function discard() {
		sync();
		toast('Alterações descartadas');
	}

	const inputCls = `${CONTROL_CLASS} ${CONTROL_PX} ${CONTROL_H} w-full`;

	// O endereço em uma linha, para a leitura de quem não edita. Junta só o que existe: uma
	// clínica que só preencheu a cidade não deve ler "— , — - SP".
	const enderecoLinha = $derived(
		[
			[data.clinic.endereco, data.clinic.numero].filter(Boolean).join(', '),
			data.clinic.complemento,
			data.clinic.bairro,
			[data.clinic.cidade, data.clinic.uf].filter(Boolean).join('/'),
			data.clinic.cep
		]
			.filter((parte) => parte && String(parte).trim() !== '')
			.join(' · ')
	);
</script>

<svelte:head><title>Clínica · Cinetra</title></svelte:head>

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-6">
	<section class="mb-3 rounded-cartao border border-edge bg-surface p-4">
		{#if canManage}
			<form method="POST" action="?/save" use:enhance={save.submit} class="space-y-4">
				<div class="grid grid-cols-1 gap-3 md:grid-cols-2">
					<div>
						<label for="nome" class="mb-1 block text-rotulo font-medium text-muted">
							Nome da clínica <span class="text-danger">*</span>
						</label>
						<input
							id="nome"
							name="nome"
							bind:value={f.nome}
							maxlength="160"
							placeholder="ex.: Clínica Vida"
							class={inputCls}
						/>
					</div>

					<div>
						<label for="cnpj" class="mb-1 block text-rotulo font-medium text-muted">CNPJ</label>
						<input
							id="cnpj"
							name="cnpj"
							value={f.cnpj}
							oninput={(e) => (f.cnpj = maskCnpj(e.currentTarget.value))}
							inputmode="text"
							autocapitalize="characters"
							placeholder="00.000.000/0000-00"
							aria-invalid={cnpjInvalido}
							class="{inputCls} font-mono {cnpjInvalido ? 'border-danger' : ''}"
						/>
						{#if cnpjInvalido}
							<p class="mt-1 text-rotulo text-danger">CNPJ inválido.</p>
						{/if}
					</div>
				</div>

				<div class="border-t border-edge pt-4">
					<label for="telefone" class="mb-1 block text-rotulo font-medium text-muted">
						Telefone da clínica
					</label>
					<input
						id="telefone"
						name="telefone"
						value={f.telefone}
						oninput={(e) => (f.telefone = maskTel(e.currentTarget.value))}
						inputmode="tel"
						placeholder="(11) 3456-7890"
						aria-invalid={telefoneApagado}
						class="{inputCls} max-w-[240px] font-mono {telefoneApagado ? 'border-danger' : ''}"
					/>
					<p class="mt-1.5 flex items-start gap-1.5 text-rotulo text-muted">
						<span class="mt-0.5 shrink-0 text-faint"><Info size={13} /></span>
						<span>
							É o número que aparece <strong>dentro da mensagem</strong> ao paciente, para quem
							precisar falar com alguém. Sem ele, o WhatsApp não pode ser ligado em Comunicação.
						</span>
					</p>
					{#if telefoneApagado}
						<p class="mt-1 text-rotulo text-danger">
							O WhatsApp está ligado em Comunicação e precisa deste número. Desligue o canal lá
							antes de apagar o telefone.
						</p>
					{/if}
				</div>

				<div class="border-t border-edge pt-4">
					<AddressFields campos={f} {inputCls} />
					<!-- Os campos do endereço são desenhados pelo componente, que não sabe de formulário.
					     Os `hidden` são o que os faz atravessar o POST — e ficam aqui, junto do form que
					     os envia, em vez de dentro de um componente que também é usado sem form. -->
					<input type="hidden" name="cep" value={f.cep} />
					<input type="hidden" name="endereco" value={f.endereco} />
					<input type="hidden" name="numero" value={f.numero} />
					<input type="hidden" name="complemento" value={f.complemento} />
					<input type="hidden" name="bairro" value={f.bairro} />
					<input type="hidden" name="cidade" value={f.cidade} />
					<input type="hidden" name="uf" value={f.uf} />
				</div>

				<div class="flex items-center gap-2.5 border-t border-edge pt-3.5">
					<div
						class="flex flex-1 items-center gap-1.5 text-rotulo {cnpjInvalido || telefoneApagado
							? 'font-semibold text-danger'
							: dirty
								? 'font-semibold text-warning'
								: 'text-faint'}"
					>
						{#if cnpjInvalido}
							<Circle size={8} class="fill-danger text-danger" /> Corrija o CNPJ.
						{:else if telefoneApagado}
							<Circle size={8} class="fill-danger text-danger" /> O telefone é obrigatório.
						{:else if dirty}
							<Circle size={8} class="fill-warning text-warning" /> Alterações não salvas
						{:else}
							O nome aparece no topo do menu lateral.
						{/if}
					</div>

					{#if dirty}
						<button
							type="button"
							onclick={discard}
							class="rounded-controle border border-edge bg-surface px-3.5 py-2 text-corpo font-semibold text-muted hover:bg-surface-2"
						>
							Descartar
						</button>
					{/if}

					<Button type="submit" emVoo={save.emVoo} disabled={!podeSalvar}>Salvar</Button>
				</div>
			</form>
		{:else}
			<!-- Leitura para não-gestores: a ficha sem os controles de edição. -->
			<h2 class="mb-3 text-leitura font-semibold">Dados da clínica</h2>
			<dl class="space-y-2.5 text-corpo">
				<div class="flex gap-3">
					<dt class="w-[90px] shrink-0 text-muted">Nome</dt>
					<dd class="font-medium">{data.clinic.nome}</dd>
				</div>
				<div class="flex gap-3">
					<dt class="w-[90px] shrink-0 text-muted">CNPJ</dt>
					<dd class="font-mono">{data.clinic.cnpj ? maskCnpj(data.clinic.cnpj) : '—'}</dd>
				</div>
				<div class="flex gap-3">
					<dt class="w-[90px] shrink-0 text-muted">Telefone</dt>
					<dd class="font-mono">{data.clinic.telefone ?? '—'}</dd>
				</div>
				<div class="flex gap-3">
					<dt class="w-[90px] shrink-0 text-muted">Endereço</dt>
					<dd>{enderecoLinha || '—'}</dd>
				</div>
			</dl>
		{/if}
	</section>
</div>
