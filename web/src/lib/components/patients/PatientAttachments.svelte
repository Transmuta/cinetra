<script module lang="ts">
	/**
	 * Falha com mensagem **escrita para a recepção ler**.
	 *
	 * O upload tem três passos e o erro de qualquer um deles precisa chegar ao toast, então o
	 * caminho natural era `throw new Error(msg)` e `catch (e) => toast(e.message)`. Só que aí
	 * QUALQUER exceção passa a ser tratada como mensagem de tela — e as duas mais fáceis de
	 * acontecer não são nossas: `res.json()` num corpo que não é JSON (502 com HTML do proxy, 413
	 * do teto) levanta `SyntaxError: Unexpected token '<'`, e o `fetch` que morre no meio levanta
	 * `TypeError: Failed to fetch`. As duas iam para o toast, em inglês, verbatim.
	 *
	 * Com o marcador o padrão inverte: só o que passou por aqui é exibível, e o desconhecido cai na
	 * genérica **por construção** — inclusive o erro que alguém introduzir neste bloco amanhã.
	 */
	class FalhaVisivel extends Error {}

	/**
	 * Chamada ao BFF que **nunca levanta** — nem por rede, nem por corpo ilegível.
	 *
	 * As quatro operações desta seção (enviar, abrir, remover, renomear) faziam o mesmo par
	 * `fetch` + `res.json()`, e as duas metades tinham o mesmo furo: o `fetch` que rejeita não
	 * estava dentro de try nenhum em três delas (rede fora = promise solta e tela muda), e o
	 * `.json()` só era tolerante em duas — nas outras, um 502 com HTML do proxy virava
	 * `SyntaxError` no lugar da mensagem da tela.
	 *
	 * Aqui as duas falhas colapsam em `{ ok: false, body: {} }`, e a frase que a pessoa lê é
	 * sempre a do `??` de quem chamou.
	 */
	async function pedir<T>(
		url: string,
		init: RequestInit
	): Promise<{ ok: boolean; body: Partial<T> & { error?: string } }> {
		try {
			const res = await fetch(url, init);
			return { ok: res.ok, body: await res.json().catch(() => ({})) };
		} catch {
			return { ok: false, body: {} };
		}
	}
</script>

<script lang="ts">
	// "Anexos e documentos" da ficha do paciente (doc 51) — o cartão que o protótipo desenhava
	// ([`:962`]) e que a v1 tinha deixado de fora com o prontuário.
	//
	// A interação é a do protótipo: drop-zone, lista compacta, abrir, remover. A MECÂNICA não tem
	// nada a ver com ele:
	//
	//   protótipo                          aqui
	//   URL.createObjectURL (blob efêmero) → objeto em bucket privado no R2
	//   f.type do browser                  → magic bytes conferidos no servidor
	//   "até 10 MB" como texto na tela     → teto assinado na URL e reconferido no HEAD
	//   sem trilha                         → cada abertura vira linha de auditoria LGPD
	//
	// Os bytes vão do browser DIRETO ao bucket (o BFF só entrega a URL assinada), então um arquivo
	// de 50 MB nunca ocupa memória do Node nem do BEAM.
	import Upload from '@lucide/svelte/icons/upload';
	import FileText from '@lucide/svelte/icons/file-text';
	import ImageIcon from '@lucide/svelte/icons/image';
	import ExternalLink from '@lucide/svelte/icons/external-link';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import Pencil from '@lucide/svelte/icons/pencil';
	import Paperclip from '@lucide/svelte/icons/paperclip';
	import LoaderCircle from '@lucide/svelte/icons/loader-circle';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import { toast } from '$lib/toast.svelte';
	import { reportar } from '$lib/report';
	import {
		fmtBytes,
		fmtData,
		isImagem,
		rotuloTipo,
		acceptAttr,
		type Attachment,
		type AttachmentLimits,
		type UploadTicket
	} from '$lib/attachments';

	let {
		patientId,
		attachments,
		limites,
		onChanged
	}: {
		patientId: string;
		attachments: Attachment[];
		/** tetos e allowlist vêm do SERVIDOR — nunca repetidos aqui (doc 51 §D-3) */
		limites: AttachmentLimits | null;
		/** recarrega a ficha; o pai é dono do `invalidateAll` */
		onChanged: () => void;
	} = $props();

	// O BFF EXIGE este header nos mutadores, e a razão é de segurança, não de forma: sem
	// content-type, um `POST` cru de outra origem atravessa a proteção CSRF do SvelteKit (que só
	// olha content-type de formulário) e ainda é *simple request* de CORS, logo sem preflight.
	// Ver `$lib/server/csrf`.
	const JSON_HEADER = { 'content-type': 'application/json' };

	// Estado só de UI. A lista de verdade é `attachments`, que vem do `load` — depois de cada
	// operação o pai recarrega, e não há cópia local para divergir.
	let arrastando = $state(false);
	let enviando = $state<{ nome: string; pct: number } | null>(null);
	let removendo = $state<Attachment | null>(null);
	let renomeando = $state<Attachment | null>(null);
	let novoNome = $state('');
	let input = $state<HTMLInputElement | null>(null);

	const maxBytes = $derived(limites?.max_bytes ?? 0);
	const tipos = $derived(limites?.tipos ?? []);
	const cheio = $derived(!!limites && attachments.length >= limites.max_por_paciente);

	function rotuloLimite(): string {
		if (!limites) return '';
		const tiposCurtos = tipos.map(rotuloTipo).join(', ');
		return `${tiposCurtos} · até ${fmtBytes(maxBytes)} por arquivo`;
	}

	// Um por vez (decisão da fatia; vários de uma vez é evolução prevista). Pegar só o primeiro
	// e avisar é melhor que ignorar em silêncio quem arrastou três.
	function receber(lista: FileList | null | undefined) {
		arrastando = false;
		const arquivos = Array.from(lista ?? []);
		if (arquivos.length === 0) return;
		if (arquivos.length > 1) toast('Envie um arquivo por vez.', 'error');
		enviar(arquivos[0]);
	}

	// A validação local existe para dar resposta imediata, não para proteger nada: quem protege é
	// o servidor (allowlist + magic bytes + tamanho assinado). Duplicar a regra aqui seria
	// perigoso; consultá-la do `limites` do servidor, não.
	function recusar(f: File): string | null {
		if (tipos.length && !tipos.includes(f.type)) {
			return `Envie um ${tipos.map(rotuloTipo).join(', ')}.`;
		}
		if (maxBytes && f.size > maxBytes) return `O arquivo passa do limite de ${fmtBytes(maxBytes)}.`;
		if (f.size === 0) return 'O arquivo está vazio.';
		return null;
	}

	async function enviar(f: File) {
		const problema = recusar(f);
		if (problema) return toast(problema, 'error');

		enviando = { nome: f.name, pct: 0 };

		try {
			// 1. a API cria a linha pendente e assina o PUT (tipo e tamanho vão DENTRO da assinatura)
			const inicio = await pedir<{ attachment: Attachment; upload: UploadTicket }>(
				`/pacientes/${patientId}/anexos`,
				{
					method: 'POST',
					headers: JSON_HEADER,
					body: JSON.stringify({ nome: f.name, content_type: f.type, bytes: f.size })
				}
			);
			// A checagem de FORMA anda junto com a de status de propósito: um 201 com corpo torto
			// levava um `undefined.url` para o toast ("Cannot read properties of undefined"), que é
			// mensagem de sistema tanto quanto a do parser.
			if (!inicio.ok || !inicio.body.upload || !inicio.body.attachment) {
				throw new FalhaVisivel(inicio.body.error ?? 'Não foi possível iniciar o envio.');
			}

			// 2. os bytes vão direto ao bucket
			await subir(inicio.body.upload.url, inicio.body.upload.headers, f);

			// 3. a API confere o que chegou (tamanho real + magic bytes) e libera
			const fim = await pedir(`/pacientes/${patientId}/anexos/${inicio.body.attachment.id}`, {
				method: 'POST',
				headers: JSON_HEADER
			});
			if (!fim.ok) {
				throw new FalhaVisivel(fim.body.error ?? 'O arquivo enviado não passou na verificação.');
			}

			toast('Anexo adicionado');
			onChanged();
		} catch (e) {
			// Só mensagem nossa vai para a tela. O resto é bug — e bug **não desaparece**: vai para o
			// log do servidor pelo `reportar` (doc 62 §7.2), com stack e agrupamento, em vez de ser
			// lido em inglês pela recepção e esquecido.
			if (!(e instanceof FalhaVisivel)) reportar('anexos:upload', e);
			toast(e instanceof FalhaVisivel ? e.message : 'Falha ao enviar o arquivo.', 'error');
		} finally {
			enviando = null;
			if (input) input.value = '';
		}
	}

	// `XMLHttpRequest` e não `fetch` por um motivo só: progresso. Um laudo de 40 MB em conexão de
	// clínica leva dezenas de segundos, e `fetch` não expõe upload progress — a barra ficaria
	// parada e o usuário sairia da página achando que travou.
	function subir(url: string, headers: Record<string, string>, f: File): Promise<void> {
		return new Promise((resolve, reject) => {
			const xhr = new XMLHttpRequest();
			xhr.open('PUT', url, true);

			// Só o content-type: o `content-length` também está assinado, mas o browser o envia
			// sozinho a partir do File e proíbe o JS de escrevê-lo.
			for (const [k, v] of Object.entries(headers)) xhr.setRequestHeader(k, v);

			xhr.upload.onprogress = (ev) => {
				if (ev.lengthComputable && enviando) {
					enviando = { ...enviando, pct: Math.round((ev.loaded / ev.total) * 100) };
				}
			};

			xhr.onload = () =>
				xhr.status >= 200 && xhr.status < 300
					? resolve()
					: reject(new FalhaVisivel('O storage recusou o arquivo.'));
			xhr.onerror = () => reject(new FalhaVisivel('Falha de rede ao enviar o arquivo.'));
			xhr.send(f);
		});
	}

	// Abrir passa pelo BFF para pegar uma URL nova a cada clique: a assinatura dura minutos, e a
	// emissão é o que fica na trilha LGPD. Guardar a URL no cliente quebraria as duas coisas.
	async function abrir(a: Attachment) {
		const { ok, body } = await pedir<{ url: string }>(
			`/pacientes/${patientId}/anexos/${a.id}?acao=download`,
			{ method: 'POST', headers: JSON_HEADER }
		);

		if (!ok || !body.url) return toast(body.error ?? 'Não foi possível abrir.', 'error');
		window.open(body.url, '_blank', 'noopener,noreferrer');
	}

	async function confirmarRemocao() {
		const alvo = removendo;
		if (!alvo) return;
		removendo = null;

		const { ok, body } = await pedir(`/pacientes/${patientId}/anexos/${alvo.id}`, {
			method: 'DELETE',
			headers: JSON_HEADER
		});
		if (!ok) return toast(body.error ?? 'Não foi possível remover.', 'error');

		toast('Anexo removido');
		onChanged();
	}

	async function salvarNome(ev: SubmitEvent) {
		ev.preventDefault();
		const alvo = renomeando;
		const nome = novoNome.trim();
		if (!alvo || !nome) return;

		renomeando = null;

		const { ok, body } = await pedir(`/pacientes/${patientId}/anexos/${alvo.id}`, {
			method: 'PATCH',
			headers: JSON_HEADER,
			body: JSON.stringify({ nome })
		});

		if (!ok) return toast(body.error ?? 'Não foi possível renomear.', 'error');

		toast('Anexo renomeado');
		onChanged();
	}
</script>

<section class="rounded-[14px] border border-edge bg-surface p-5">
	<div class="mb-4 flex items-center gap-2.5">
		<span class="grid size-[30px] shrink-0 place-items-center rounded-lg bg-accent-subtle text-accent-text">
			<Paperclip size={15} />
		</span>
		<div class="flex-1 text-[14px] font-bold">Anexos e documentos</div>
		{#if attachments.length}
			<span class="font-mono text-[11.5px] text-faint">
				{attachments.length} arquivo{attachments.length === 1 ? '' : 's'}
			</span>
		{/if}
	</div>

	{#if !limites}
		<!-- storage sem credencial (503): a seção diz o que houve em vez de oferecer um campo
		     que não tem para onde enviar. -->
		<p class="rounded-[10px] border border-edge bg-surface-2 px-3.5 py-3 text-[12.5px] text-muted">
			O storage de anexos não está configurado. Fale com quem administra o sistema.
		</p>
	{:else}
		{#if enviando}
			<div class="mb-2.5 rounded-[10px] border border-edge bg-surface-2 px-3.5 py-3">
				<div class="mb-1.5 flex items-center gap-2 text-[12.5px] font-semibold">
					<LoaderCircle size={14} class="animate-spin text-accent-text" />
					<span class="min-w-0 flex-1 truncate">{enviando.nome}</span>
					<span class="font-mono text-[11px] text-faint">{enviando.pct}%</span>
				</div>
				<div class="h-1.5 overflow-hidden rounded-full bg-edge">
					<div class="h-full rounded-full bg-accent transition-[width]" style="width:{enviando.pct}%"></div>
				</div>
			</div>
		{:else if cheio}
			<p class="mb-2.5 rounded-[10px] border border-edge bg-surface-2 px-3.5 py-3 text-[12.5px] text-muted">
				Este paciente atingiu o limite de {limites.max_por_paciente} anexos. Remova algum para enviar
				outro.
			</p>
		{:else}
			<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
			<!--
				`focus-within:*` é o par obrigatório do `sr-only` no input (ACC-01): o input fica
				invisível mas focável, então é a ZONA que precisa mostrar o foco — sem isso a pessoa
				tabula até aqui e nada acende na tela (2.4.7). O visual é o mesmo do arraste, que já
				significa "solte aqui".
			-->
			<label
				class="mb-2.5 flex cursor-pointer flex-col items-center gap-1.5 rounded-[10px] border-[1.5px] border-dashed p-[18px] transition-colors focus-within:border-accent focus-within:bg-accent-subtle focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-accent {arrastando
					? 'border-accent bg-accent-subtle'
					: 'border-edge-strong bg-surface'}"
				ondragover={(e) => {
					e.preventDefault();
					arrastando = true;
				}}
				ondragleave={(e) => {
					e.preventDefault();
					arrastando = false;
				}}
				ondrop={(e) => {
					e.preventDefault();
					receber(e.dataTransfer?.files);
				}}
			>
				<!--
					`sr-only`, e NÃO `hidden` (ACC-01, doc 83): `display:none` tira o elemento da ordem
					de tabulação inteira, e como a `<label>` também não é focável, não havia **nenhum**
					caminho de teclado para anexar — nível A. `sr-only` esconde da vista mantendo o
					input focável e com nome acessível (o texto da label). O clique na zona continua
					funcionando igual.
				-->
				<input
					bind:this={input}
					type="file"
					accept={acceptAttr(tipos)}
					class="sr-only"
					onchange={(e) => receber((e.currentTarget as HTMLInputElement).files)}
				/>
				<Upload size={20} class="text-accent-text" />
				<span class="text-[12.5px] font-semibold text-ink">Arraste um arquivo ou clique para enviar</span>
				<span class="text-[11px] text-faint">{rotuloLimite()}</span>
			</label>
		{/if}

		{#if attachments.length}
			<ul class="flex flex-col gap-1.5">
				{#each attachments as a (a.id)}
					<li class="flex items-center gap-2.75 rounded-[9px] border border-edge bg-surface p-2">
						<span
							class="grid size-[38px] shrink-0 place-items-center rounded-[7px] {isImagem(a.content_type)
								? 'bg-surface-2 text-muted'
								: 'bg-danger/10 text-danger'}"
						>
							{#if isImagem(a.content_type)}
								<ImageIcon size={18} />
							{:else}
								<FileText size={18} />
							{/if}
						</span>

						<div class="min-w-0 flex-1">
							<div class="truncate text-[12.5px] font-semibold">{a.nome}</div>
							<div class="font-mono text-[11px] text-faint">
								{rotuloTipo(a.content_type)} · {fmtBytes(a.bytes)} · {fmtData(a.inserted_at)}
							</div>
						</div>

						<button
							type="button"
							title="Abrir"
							aria-label="Abrir {a.nome}"
							onclick={() => abrir(a)}
							class="grid size-8 shrink-0 place-items-center rounded-lg text-muted hover:bg-surface-2 hover:text-ink"
						>
							<ExternalLink size={15} />
						</button>
						<button
							type="button"
							title="Renomear"
							aria-label="Renomear {a.nome}"
							onclick={() => {
								renomeando = a;
								novoNome = a.nome;
							}}
							class="grid size-8 shrink-0 place-items-center rounded-lg text-muted hover:bg-surface-2 hover:text-ink"
						>
							<Pencil size={15} />
						</button>
						<button
							type="button"
							title="Remover"
							aria-label="Remover {a.nome}"
							onclick={() => (removendo = a)}
							class="grid size-8 shrink-0 place-items-center rounded-lg text-muted hover:bg-danger/10 hover:text-danger"
						>
							<Trash2 size={15} />
						</button>
					</li>
				{/each}
			</ul>
		{:else if !enviando}
			<p class="py-2 text-center text-[12.5px] text-faint">Nenhum anexo ainda.</p>
		{/if}
	{/if}
</section>

{#if renomeando}
	<div class="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4">
		<form
			onsubmit={salvarNome}
			class="w-full max-w-sm rounded-[14px] border border-edge bg-surface p-5 shadow-lg"
		>
			<h2 class="mb-3 text-[15px] font-bold">Renomear anexo</h2>
			<!-- svelte-ignore a11y_autofocus -->
			<input
				bind:value={novoNome}
				autofocus
				maxlength="200"
				aria-label="Nome do anexo"
				class="mb-4 w-full rounded-lg border border-edge bg-surface-2 px-3 py-2 text-[13.5px] outline-none focus:border-accent"
			/>
			<div class="flex justify-end gap-2">
				<button
					type="button"
					onclick={() => (renomeando = null)}
					class="rounded-lg border border-edge px-3.5 py-2 text-[13px] font-semibold text-muted hover:bg-surface-2"
				>
					Cancelar
				</button>
				<button
					type="submit"
					disabled={!novoNome.trim()}
					class="rounded-lg bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary disabled:opacity-50"
				>
					Salvar
				</button>
			</div>
		</form>
	</div>
{/if}

{#if removendo}
	<ConfirmDialog
		title="Remover anexo"
		confirmLabel="Remover"
		onConfirm={confirmarRemocao}
		onClose={() => (removendo = null)}
	>
		<strong>{removendo.nome}</strong> será apagado do storage, não só desta lista. Não há como
		recuperar.
	</ConfirmDialog>
{/if}
