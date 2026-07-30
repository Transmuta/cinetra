// Um `$app/state` de mentira — mas **reativo**.
//
// Testes de página mockam `$app/state` com um objeto solto, e isso basta enquanto a tela só LÊ a
// URL no primeiro render. Não basta quando ela deriva comportamento dela: um objeto comum não
// notifica ninguém ao mudar, então o `$derived` da tela nunca recalcula e o teste "passa" mostrando
// o estado inicial para sempre.
//
// Foi assim que a primeira versão do drawer-na-URL da agenda passou na unidade e falhou no browser:
// o clique mudava a URL e o painel não abria. Daí o `$state` daqui (e o `.svelte.ts`, que é o que
// permite runes fora de componente).
//
// `state` existe porque **shallow routing** (`pushState`/`replaceState`) escreve em `page.state` e
// deliberadamente NÃO em `page.url` — quem testa uma tela que abre painel por URL precisa das duas
// pontas, cada uma com o comportamento real.
export const fake = $state({
	href: 'http://localhost/',
	estado: {} as Record<string, unknown>
});

/** O que vai no lugar do `page` do `$app/state`. */
export const page = {
	get url() {
		return new URL(fake.href);
	},
	get state() {
		return fake.estado;
	}
};

/** Volta ao estado limpo — chame no `beforeEach`. */
export function resetFakePage(href = 'http://localhost/') {
	fake.href = href;
	fake.estado = {};
}
