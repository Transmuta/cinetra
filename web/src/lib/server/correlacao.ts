/**
 * Correlação de requisição entre o BFF e a API (doc 62 §12).
 *
 * Um id de requisição atravessando as fronteiras, que responde "o que aconteceu nesta requisição".
 *
 * Este módulo cuida da primeira fronteira: BFF → API. A segunda (requisição → job do Oban) é do
 * lado Elixir, em `Api.Correlacao`.
 *
 * > **Atualizado em 2026-07-29:** o projeto passou a ter tracing (doc 76), e isto **não foi
 * > substituído**. O `traceparent` que o `undici` injeta no mesmo `fetch` cobre a mesma fronteira
 * > com muito mais detalhe, mas só existe quando o trace está ligado e amostrado, e vive 7 dias
 * > contra os 30 do log. O `request_id` é o que sobra nos outros casos — e é ele que aparece na
 * > linha do job do Oban.
 */

/**
 * A faixa de tamanho que o `Plug.RequestId` do lado Elixir aceita.
 *
 * Ele só REAPROVEITA o header `x-request-id` quando `byte_size(val) in 20..200`; fora disso
 * descarta e gera o próprio id — **em silêncio**. Esse é o modo de falha a temer aqui: o header
 * sai, nada dá erro, os dois lados parecem corretos em revisão de código, e a correlação
 * simplesmente não existe. Por isso a faixa é constante exportada e testada, em vez de um
 * comentário sobre um número mágico.
 */
export const LIMITE_PLUG = { min: 20, max: 200 } as const;

/**
 * Um id por requisição do BFF.
 *
 * O prefixo `bff-` não é enfeite: ele distingue, no log, o id que nasceu aqui daquele que o
 * Phoenix gerou por conta própria. Ver um `request_id` sem prefixo numa rota que passa pelo BFF é
 * o sintoma de que a propagação parou de funcionar.
 *
 * `randomUUID` dá 36 caracteres; com o prefixo, 40 — folgadamente dentro de `LIMITE_PLUG` e
 * restrito a caracteres seguros para header HTTP.
 */
export function novoRequestId(): string {
	return `bff-${crypto.randomUUID()}`;
}
