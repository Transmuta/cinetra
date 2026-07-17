import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

import SwitchToggle from './SwitchToggle.svelte';

describe('SwitchToggle', () => {
	it('expõe o estado por aria-checked', () => {
		const { getByRole } = render(SwitchToggle, {
			props: { checked: true, label: 'Segunda', onchange: () => {} }
		});
		expect(getByRole('switch', { name: 'Segunda' })).toHaveAttribute('aria-checked', 'true');
	});

	it('clique dispara onchange', async () => {
		const onchange = vi.fn();
		const { getByRole } = render(SwitchToggle, { props: { checked: false, onchange } });
		await fireEvent.click(getByRole('switch'));
		expect(onchange).toHaveBeenCalledOnce();
	});

	it('desabilitado não dispara', async () => {
		const onchange = vi.fn();
		const { getByRole } = render(SwitchToggle, {
			props: { checked: false, disabled: true, onchange }
		});
		await fireEvent.click(getByRole('switch'));
		expect(onchange).not.toHaveBeenCalled();
	});
});
