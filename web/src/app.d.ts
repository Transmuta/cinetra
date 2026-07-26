// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
declare global {
	// Assado pelo `define` do vite.config.ts (D2, doc 47): o `connect-src` que a CSP desta build
	// autoriza. O `hooks.server.ts` o compara com a origem de runtime no boot do servidor.
	const __CSP_CONNECT_SRC__: string[];

	namespace App {
		// interface Error {}
		// interface Locals {}
		// interface PageData {}
		// interface PageState {}
		// interface Platform {}
	}
}

export {};
