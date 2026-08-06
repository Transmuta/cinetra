import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchClinic, updateClinicMessaging } from '$lib/server/clinics';

// O que a clínica manda ao paciente, e quando (doc 52 §7).
//
// Como as demais telas de config: todo membro LÊ, só owner/admin escreve (policy da API + o
// `canManage` da página). O load reusa `GET /api/clinic` — os campos de comunicação viajam com a
// identidade, e uma rota só para três escalares seria um round-trip a mais.

export const load: PageServerLoad = async (event) => {
	const result = await fetchClinic(event);

	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar a configuração de comunicação.');
	}

	return { clinic: result.data.clinic };
};

export const actions: Actions = {
	save: async (event) => {
		const form = await event.request.formData();

		const silencio = form.get('silencio') === 'on';

		const res = await updateClinicMessaging(event, {
			// Como o `silencio`: o `SwitchToggle` é um `<button role="switch">` e não entra no
			// FormData, então quem manda o valor é um `<input type="hidden">` na página. Ausente é
			// `false` — e é isso que torna o interruptor desligável. Ver o doc 98 §6, onde a mesma
			// armadilha apagou a janela de silêncio em produção.
			msg_whatsapp_ativo: form.get('whatsapp') === 'on',
			// Desligar a janela é mandar as duas pontas em `nil` — a API trata "sem janela" e
			// "janela de largura zero" como a mesma coisa (nada silenciado), e mandar só uma
			// deixaria um estado meio-configurado que a tela não sabe desenhar.
			msg_silencio_inicio: silencio ? Number(form.get('msg_silencio_inicio') ?? 21) : null,
			msg_silencio_fim: silencio ? Number(form.get('msg_silencio_fim') ?? 8) : null
		});

		if (!res.ok) return fail(res.status || 400, { error: res.error });
		return { ok: true };
	}
};
