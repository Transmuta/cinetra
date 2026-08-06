# 106 — O "Volume por dia" vira calendário

**Data:** 2026-08-05 · **Fatia:** Relatórios (doc 33, Fatia 9) · **Origem:** relato do usuário —
"o relatório *volume por dia* está bem esquisito".

O gráfico era uma série de barras verticais, uma por dia da janela. O relato era estético; a causa
não é. Este doc registra a medição, a troca e o que ela abriu.

## 1. Por que estava esquisito

**Um gráfico só servia janelas de 6 a 90 dias.** `por_dia` traz *toda* data do
`Date.range(from, to)`, e a barra dividia a largura do cartão entre elas:

| Preset | Barras | Largura por barra (cartão ~970px, gap 6px) |
| --- | --- | --- |
| Esta semana | 6 | ~145px de largura para 132px de altura — tijolos |
| Este mês | 30 | ~26px — o único caso que funcionava |
| Últimos 90 dias | 90 | **~4,8px** — o vão maior que a barra |

No celular (gap 3px, cartão ~310px) o trimestre dava **0,5px por barra**: um pente de fios de
cabelo. Os dois extremos estavam quebrados; o mês, que é o default, era o que segurava a
impressão de que o gráfico funcionava.

Havia mais quatro defeitos que a troca resolve junto:

1. **Fim de semana ocupava a mesma largura de um dia útil.** O cliente não recebia capacidade por
   dia — o servidor calculava `summary_capacidade_por_dia`, usava para `dias_uteis` e **descartava**.
   "Clínica fechada" e "dia aberto sem ninguém" desenhavam a mesma coluna vazia: num mês, ~9
   buracos que se leem como falha de dado.
2. **Duas codificações na mesma marca.** Altura = total, preenchimento = % de concluídos. Um dia
   2/2 ficava todo pintado e baixo; 10/20 ficava meio pintado e alto. E "Composição por status",
   no cartão ao lado, já contava essa história.
3. **Nenhum valor legível.** Sem eixo, sem gridline; o número só existia no `title=` — hover de
   mouse. É o mesmo **ACC-10** (doc 83) que os KPIs desta tela já tinham corrigido, sobrevivendo
   no gráfico logo abaixo deles.
4. **Rótulo sem mês.** No trimestre saíam só as segundas: `3 10 17 24 1 8…`, com o "1" repetindo
   três vezes.

## 2. O que entrou

Três desenhos, escolhidos pela janela (`volumeMode/1` em `web/src/lib/reports.ts`):

| Janela | Desenho |
| --- | --- |
| 1 dia | por profissional (inalterado — "por dia" degenera) |
| ≤ 8 dias | **linhas horizontais por dia**, com nome do dia da semana (`VolumeSemana.svelte`) |
| > 8 dias | **heatmap de calendário** semana × dia-da-semana (`VolumeCalendario.svelte`) |

O calendário resolve a largura por construção: a célula tem tamanho fixo, então 90 dias viram 14
colunas e o desenho para de depender do espaço disponível. Medido a 375px: `scrollWidth` 375 =
`clientWidth` 375 — sem rolagem horizontal na página, com o gráfico rolando dentro do próprio
contêiner se precisar.

E o formato **acrescenta** uma leitura que a série de barras escondia: o dia-da-semana virou uma
linha, então "toda terça cai" e "sábado rende metade" se leem de relance. A média por linha, à
direita, é o número dessa leitura — e é ela que ocupa a largura que o heatmap deixa livre num
cartão largo.

### A bandeira `aberto`

`por_dia` passou a levar `aberto: boolean` até o wire — `capacidade > 0` para o **escopo
selecionado**, o mesmo denominador da ocupação. Filtrar por quem não atende na segunda fecha a
segunda no gráfico; duas respostas divergentes para "havia expediente?" na mesma tela seria pior
que a assimetria.

No desenho: dia fechado não tem fundo, só um ponto; dia aberto e vazio é o quadrado apagado. São
coisas diferentes e agora parecem diferentes.

### Acessibilidade

- O número mora no **nome acessível** de cada célula (`"03/06: 8 atendimentos, 4 concluídos"`) e na
  linha de detalhe, que responde a hover **e** a foco. Sem `title=`.
- A grade é uma `<table>` com `<th scope>` de mês e de dia-da-semana.
- **Uma parada de Tab** para a grade inteira, com as setas andando dentro dela (`nextCell/4`, que
  pula os buracos da primeira semana). 90 células focáveis seriam 90 paradas no caminho de quem só
  quer chegar ao próximo cartão.

Medido com axe (`wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa`, tema escuro, com dado semeado): o
gráfico novo não introduz violação nenhuma. A única de `/relatorios` é o avatar do profissional
(`#7FA59A` com texto branco, 2,7:1) — pré-existente, a mesma que aparece em `/pacientes` e
`/configuracoes/equipe`, e que é o débito **D-18**.

## 3. O bug de tabela achado no caminho

Para rodar a sonda de a11y foi preciso subir a e2e, e ela **não subia**: `playwright.config.ts`
tinha **duas** chaves `env` no mesmo literal `webServer`, cada uma com seu comentário explicando
por que era necessária. Em JavaScript a segunda vence em silêncio — `ORIGIN` e `API_URL` sumiam, o
`preview` (que roda em `NODE_ENV=production`) batia na guarda de boot e morria antes do primeiro
teste.

O modo de falha é o que torna isto perigoso: **a e2e não roda no CI** (decisão de 2026-07-27),
então nada avisava, e o comentário no arquivo continuava afirmando que as três variáveis estavam
sendo passadas. Virou teste antes de virar conserto: `web/src/lib/e2e-webserver.test.ts` (mora em
`src/` porque o Vitest só enxerga `src/**`, mesmo motivo de `paridade-espelhada.test.ts`).

## 4. O que ficou de fora

- **A escala do heatmap é relativa ao maior dia da janela**, não absoluta. Trocar de mês muda o que
  "escuro" significa. É o comportamento do gráfico anterior (`barPct` contra o máximo da série) e
  mantê-lo evita uma discussão de escala que ninguém pediu — mas é uma escolha, não um acidente.
- **Nível 1 nunca some.** Um único atendimento numa janela movimentada ainda pinta, senão o
  arredondamento faria o gráfico mentir por omissão.
- A **contagem de concluídos** saiu do desenho da barra (uma marca, uma codificação) e vive agora
  no detalhe da célula e em "Composição por status".

## 5. Onde está

| Camada | Arquivo |
| --- | --- |
| domínio | `api/lib/api/scheduling/reports.ex` — `summary_por_dia/4` recebe a capacidade |
| wire | `api/lib/api_web/controllers/reports_controller.ex` — `render_dia/1` |
| lógica pura | `web/src/lib/reports.ts` — `volumeMode`, `calendarGrid`, `heatLevel`, `weekdayAverage`, `firstCell`, `nextCell` |
| componentes | `web/src/lib/components/reports/{VolumeCalendario,VolumeSemana}.svelte` |
| tela | `web/src/routes/(app)/relatorios/+page.svelte` |
