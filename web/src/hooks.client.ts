import type { HandleClientError } from '@sveltejs/kit';
import { reportar } from '$lib/report';

/**
 * Crash no browser (doc 62 §7.2).
 *
 * ## Por que isto precisa existir
 *
 * O container de log alcança o servidor. **Erro que acontece na máquina do usuário não chega a
 * lugar nenhum** — nem stdout, nem Loki, nem console de ninguém que possa agir. Sem este arquivo,
 * uma tela que quebra na recepção de uma clínica é invisível para sempre; o único sinal é a
 * pessoa ligando para reclamar.
 *
 * ## Para o nosso próprio backend, não para um SaaS
 *
 * O erro vai para `POST /api/client-error`, no BFF, e de lá para o stdout como qualquer outro log
 * — mesma retenção, mesma jurisdição, mesma disciplina de redação. Nenhum SDK de terceiro entra
 * na página: o doc 05 §1.2 recusa RUM justamente porque script de terceiro na tela é o caminho
 * mais curto para vazar identificador de paciente.
 *
 * ## O que é enviado, e o que nunca é
 *
 * Mensagem, stack e a rota **sanitizada**. Não vai estado de formulário, não vai conteúdo de
 * tela, não vai breadcrumb de navegação. A rota passa pelo mesmo filtro do servidor porque
 * `/pacientes/019f7c5b-…` carregaria o id do paciente.
 */
export const handleError: HandleClientError = ({ error, event, status, message }) => {
	// 404 é rota inexistente, não falha: registrar todos faria de qualquer varredura de robô um
	// evento de erro.
	if (status !== 404) reportar('kit', error, { route_id: event.route.id, status });

	return { message };
};

// O `handleError` do Kit **não** cobre tudo: erro dentro de um handler de evento (um clique) ou
// promise rejeitada sem `catch` passam por fora dele. Estes dois ouvintes fecham o resto.
if (typeof window !== 'undefined') {
	window.addEventListener('error', (evento) => {
		reportar('window', evento.error ?? evento.message);
	});

	window.addEventListener('unhandledrejection', (evento) => {
		reportar('promise', evento.reason);
	});
}
