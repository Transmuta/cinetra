import type { RequestHandler } from './$types';
import { searchPatients } from '$lib/server/patient-search';

// Busca de pacientes do `PatientPicker` da agenda (doc 25 §6). A regra vive em
// `$lib/server/patient-search` — era gêmea byte a byte da rota da fila (D3, doc 29 §5).
//
// É um `+server` consumido por `fetch` do cliente — não por `<a>`, então o gotcha do
// `data-sveltekit-reload` não se aplica aqui.
export const GET: RequestHandler = (event) => searchPatients(event);
