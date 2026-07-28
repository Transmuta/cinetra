import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

/**
 * Liveness do BFF (doc 62 §9.4).
 *
 * Barato, **sem I/O**: 200 significa "o processo Node está de pé e servindo". Não toca a API de
 * propósito — é o que o Traefik consulta para decidir rotear tráfego, e um BFF que sai da rotação
 * porque a API piscou deixa de servir até a página de erro. Degradar é melhor que desaparecer.
 *
 * Quem quer saber se o **produto** está usável usa `/ready`, ao lado.
 */
export const GET: RequestHandler = () => json({ status: 'ok', service: 'web' });
