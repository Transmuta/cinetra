import { describe, it, expect, vi, beforeEach } from 'vitest';

const switchTenant = vi.fn();
vi.mock('$lib/server/clinics', () => ({ switchTenant: (...a: unknown[]) => switchTenant(...a) }));

import { POST } from './+server';

beforeEach(() => switchTenant.mockReset());

function formEvent(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	const request = new Request('http://web/auth/switch-clinic', { method: 'POST', body: fd });
	return { request } as never;
}

describe('POST /auth/switch-clinic', () => {
	it('troca para a clínica do corpo e redireciona 303 para a home', async () => {
		switchTenant.mockResolvedValue({ ok: true, status: 200 });
		await expect(POST(formEvent({ clinic_id: 'c2' }))).rejects.toMatchObject({
			status: 303,
			location: '/'
		});
		expect(switchTenant).toHaveBeenCalledWith(expect.anything(), 'c2');
	});

	it('sem clinic_id → redireciona sem chamar a troca', async () => {
		await expect(POST(formEvent({}))).rejects.toMatchObject({ status: 303, location: '/' });
		expect(switchTenant).not.toHaveBeenCalled();
	});
});
