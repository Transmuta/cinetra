<script lang="ts">
	// Arte orgânica de "movimento / respiro" (Cinetra Landing.dc.html · flowArt()): linhas
	// fluindo com stroke-dashoffset animado + pontos à deriva ("sessões em movimento") sobre
	// um degradê radial. Cores parametrizadas por superfície; `k` só torna o id do gradiente
	// único quando há mais de uma arte na página.
	let {
		k = '0',
		bg = '#212A37',
		c1 = '#3A5A78',
		c2 = '#7FA59A'
	}: { k?: string; bg?: string; c1?: string; c2?: string } = $props();

	const paths = [
		'M-60 300 C 260 160 520 440 820 260 S 1260 120 1560 300',
		'M-60 380 C 300 260 540 520 860 340 S 1280 220 1560 380',
		'M-60 220 C 240 100 560 360 880 200 S 1300 60 1560 220',
		'M-60 460 C 320 360 520 600 900 420 S 1300 320 1560 460'
	];

	const dots = Array.from({ length: 7 }, (_, i) => ({
		cx: 120 + i * 190,
		cy: 250 + (i % 2 ? 70 : -40) * Math.sin(i),
		r: 5 + (i % 3),
		fill: i % 2 ? c2 : '#fff',
		opacity: 0.35 + (i % 3) * 0.12,
		dur: 6 + i,
		delay: i * 0.3
	}));
</script>

<svg
	viewBox="0 0 1440 640"
	preserveAspectRatio="xMidYMid slice"
	style="width:100%;height:100%;display:block;background:{bg}"
	aria-hidden="true"
>
	<defs>
		<radialGradient id="cnG{k}" cx="75%" cy="30%" r="70%">
			<stop offset="0%" stop-color={c2} stop-opacity="0.32" />
			<stop offset="55%" stop-color={c1} stop-opacity="0.14" />
			<stop offset="100%" stop-color={bg} stop-opacity="0" />
		</radialGradient>
	</defs>
	<rect x="0" y="0" width="1440" height="640" fill="url(#cnG{k})" />
	{#each paths as d, i (i)}
		<path
			{d}
			fill="none"
			stroke={i % 2 === 0 ? c2 : c1}
			stroke-width={2.2 - i * 0.15}
			stroke-linecap="round"
			stroke-dasharray="2600"
			stroke-dashoffset="2600"
			opacity={0.5 - i * 0.06}
			style="animation:cnFlow {5 + i * 1.2}s ease-out {i * 0.25}s forwards"
		/>
	{/each}
	{#each dots as dot, i (i)}
		<circle
			cx={dot.cx}
			cy={dot.cy}
			r={dot.r}
			fill={dot.fill}
			opacity={dot.opacity}
			style="animation:cnDrift {dot.dur}s ease-in-out {dot.delay}s infinite"
		/>
	{/each}
</svg>
