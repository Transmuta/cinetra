import { test, expect } from './autenticado';
import { foto } from './foto';
import { criarAgendamento, instanteUtc } from '../helpers';

// A única print de celular da central. Viewport próprio, declarado aqui e não na config: é o
// arquivo inteiro que fala de tela pequena, e um `use` global obrigaria todo o resto a conviver
// com 390px.
test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });

test('a agenda no celular', async ({ page, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '09:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '10:30'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	// A visão Lista, que é a que o tópico recomenda no celular.
	await page.goto(`/agenda?date=${clinica.dia}&view=lista`);
	await expect(page.getByRole('main')).toBeVisible();
	await foto(page, 'celular-agenda-01', { assentar: 800 });
});
