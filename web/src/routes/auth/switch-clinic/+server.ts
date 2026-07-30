import { redirect, type RequestEvent } from '@sveltejs/kit';
import { switchTenant } from '$lib/server/clinics';

// Troca a clínica ativa da sessão a partir do menu do usuário. POST (proteção CSRF do
// SvelteKit, igual ao sign-out): GET permitiria troca forçada por CSRF. A API valida o
// vínculo e reemite o cookie; voltamos para a home, que já renderiza no tenant novo. O menu
// só lista vínculos válidos, então um erro aqui apenas mantém o tenant atual — sem drama.
export async function POST(event: RequestEvent) {
	const form = await event.request.formData();
	const clinicId = String(form.get('clinic_id') ?? '').trim();
	if (clinicId) await switchTenant(event, clinicId);
	redirect(303, '/');
}
