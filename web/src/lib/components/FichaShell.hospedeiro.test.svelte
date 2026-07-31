<script lang="ts">
	// Hospedeiro do teste: o `children` do shell é um snippet, que só existe em marcação.
	import User from '@lucide/svelte/icons/user';
	import MapPin from '@lucide/svelte/icons/map-pin';
	import FichaShell from './FichaShell.svelte';

	let {
		nome = '',
		counts = { ident: 0, contato: 0 },
		problema = null,
		acaoDesabilitada = false
	}: {
		nome?: string;
		counts?: Record<string, number>;
		problema?: string | null;
		acaoDesabilitada?: boolean;
	} = $props();

	const SECOES = [
		{ id: 'ident', icon: User, t: 'Identificação', sub: 'Dados básicos', total: 6 },
		{ id: 'contato', icon: MapPin, t: 'Contato', sub: 'Onde encontrar', total: 4 }
	];
</script>

<FichaShell
	voltarHref="/pacientes"
	titulo="Novo paciente"
	subtitulo="Cadastro de novo paciente"
	{nome}
	corIndice={1}
	secoes={SECOES}
	{counts}
	{problema}
	dica="Nome e telefone são obrigatórios — o resto pode ficar para depois."
	acaoRotulo="Cadastrar paciente"
	{acaoDesabilitada}
>
	<section id="sec-ident">Cartão de identificação</section>
	<section id="sec-contato">Cartão de contato</section>
</FichaShell>
