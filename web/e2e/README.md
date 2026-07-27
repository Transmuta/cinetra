# E2E — como rodar, e para onde apontar

Estes testes **não rodam no CI** (decisão de 2026-07-27). Eles precisam da stack inteira — API,
banco e, nos cenários autenticados, a caixa de e-mail de dev de onde sai o magic link —, e o
workflow do CI sobe só o `web`. Um job que pula com aviso é ruído com cara de cobertura.

Um estudo sobre e2e está previsto; quando ele definir a forma, o job volta com a stack que precisa.

## Local (o caso normal)

Com o `docker compose up` de pé:

```bash
docker compose exec web npx playwright install --with-deps chromium   # 1ª vez
docker compose exec web npm run test:e2e
```

O Playwright faz `build` + `preview` sozinho na porta 4173 e fala com a API pela rede do compose
(`API_URL=http://api:4000`).

## Apontando para outro ambiente (hml, produção)

Duas variáveis, nada mais:

```bash
E2E_BASE_URL=https://hml.exemplo.com \
E2E_API_ORIGIN=https://api-hml.exemplo.com \
  npm run test:e2e
```

Com `E2E_BASE_URL` definido, o `webServer` **não sobe** — o alvo já está no ar.

| Variável | O que é | Default |
| --- | --- | --- |
| `E2E_BASE_URL` | O **web** (é a `baseURL` do Playwright) | `http://localhost:4173`, com build+preview automáticos |
| `E2E_API_ORIGIN` | A **API**, a partir do processo do Playwright | `API_URL` → `API_PUBLIC_ORIGIN` → `http://localhost:4010` |

> **Cuidado com a origem da API.** `API_PUBLIC_ORIGIN` é a origem *pelo browser do host*
> (`localhost:4010`); rodando dentro do container, a que resolve é `API_URL` (`http://api:4000`).
> Trocar as duas fez a primeira execução **pular em silêncio** achando que a stack estava fora do
> ar — que é pior que falhar.

## O que roda em cada ambiente

| Spec | Precisa de | Contra hml/prod? |
| --- | --- | --- |
| `login.spec.ts`, `theme.spec.ts` | só o web | sim |
| `switch-clinic.spec.ts` | API + banco + **caixa de dev** (`/dev/mailbox`) | **não** — sem `dev_routes` não há como ler o magic link |

Os cenários autenticados pulam sozinhos quando a caixa de dev não responde (`stackCompleta/1` em
`helpers.ts`). Em ambiente sem mailbox, autenticar exige outro caminho — é parte do que o estudo
de e2e precisa decidir.
