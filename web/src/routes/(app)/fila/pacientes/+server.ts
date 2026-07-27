import type { RequestHandler } from './$types';
import { searchPatients } from '$lib/server/patient-search';

// Busca de pacientes do `PatientPicker` do modal "Adicionar à fila" (doc 25, Entrega 5). A regra
// vive em `$lib/server/patient-search` — era gêmea byte a byte da rota da agenda (D3, doc 29 §5).
//
// É um `+server` consumido por `fetch` do cliente — não por `<a>`, então o gotcha do
// `data-sveltekit-reload` não se aplica aqui.
export const GET: RequestHandler = (event) => searchPatients(event);
