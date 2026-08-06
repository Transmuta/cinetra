import { error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { chamar } from '../resposta';
import { eventoIcs, uidDeSessao } from '$lib/server/ics';
import { descricaoDaSessao, tituloDaSessao } from '$lib/calendario';

// "Adicionar à agenda", oferecido a quem acabou de confirmar presença (doc 52 §5).
//
// Uma rota, e não um `data:` no `href` nem um Blob montado no browser: o Chrome bloqueia
// navegação de topo para `data:`, e o iOS não baixa Blob de forma confiável — as duas
// alternativas falham no aparelho em que esta tela mais é aberta.
//
// Serve o **mesmo token** da página, então não amplia nada: quem chega aqui já podia responder
// pela pessoa. O que ela não faz é gravar o token dentro do arquivo — o `.ics` acaba em
// calendário compartilhado com a família, e o UID é digest justamente por isso.

export const GET: RequestHandler = async (event) => {
	const { resumo } = await chamar(event, event.params.token);

	// Sem instante não há evento. Preencher com uma duração-padrão poria o paciente na clínica na
	// hora errada — pior que não oferecer o botão.
	if (!resumo?.inicio || !resumo.fim) error(404, 'Sessão não encontrada');

	// Cancelada depois do envio: o link ainda vale 30 dias, e a sessão não existe mais.
	if (!resumo.ativa) error(404, 'Esta sessão foi cancelada');

	// Título e descrição vêm de `$lib/calendario` porque a tela monta o link do Google com os
	// mesmos textos — e o que o paciente lê no calendário não pode depender de por qual dos dois
	// botões ele entrou.
	const corpo = eventoIcs({
		uid: uidDeSessao(event.params.token),
		inicio: resumo.inicio,
		fim: resumo.fim,
		titulo: tituloDaSessao(resumo.clinica),
		descricao: descricaoDaSessao(resumo.clinica, resumo.clinica_telefone),
		agora: new Date().toISOString()
	});

	return new Response(corpo, {
		headers: {
			'content-type': 'text/calendar; charset=utf-8',
			// `inline`, e NÃO `attachment`: medido no celular, `attachment` faz o Safari (iOS 13+)
			// baixar o arquivo para o app Arquivos em vez de abrir a folha nativa "Adicionar ao
			// Calendário" — a pessoa toca no botão e precisa sair do navegador para achar o que
			// baixou. O `filename` continua, para quem de fato salvar não receber um `sessao` solto.
			'content-disposition': 'inline; filename="sessao.ics"',
			// A sessão pode ser remarcada depois de o arquivo ser gerado; um intermediário guardando
			// esta resposta entregaria o horário velho a quem clicar de novo.
			'cache-control': 'no-store'
		}
	});
};
