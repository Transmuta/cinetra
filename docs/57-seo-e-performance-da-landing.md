# 57 — SEO e performance da landing

A landing pública (`/`, [doc de marca](../web/src/routes/+page.svelte)) nasceu do protótipo
`interface/Cinetra Landing.dc.html` como fidelidade visual: nunca tinha sido medida. Este
documento é o que a medição encontrou e o que foi feito. Entregue em 2026-07-27.

O pedido foi "um trabalho bom de SEO e no mínimo 90 no Lighthouse".

## Resultado

Build de produção (`npm run build` no container) servido por `node build/`, Lighthouse 13.4.1
em Chromium headless, preset mobile padrão (4× de CPU, 4G lento). Três execuções.

| Categoria | Antes | Depois | Pior de 3 |
| --- | --- | --- | --- |
| Performance | **88** | **99** | 98 |
| Acessibilidade | **95** | **100** | 100 |
| Boas práticas | **93** | **100** | 100 |
| SEO | **100** | **100** | 100 |

| Métrica | Antes | Depois |
| --- | --- | --- |
| FCP | 2,1 s | 1,5 s |
| LCP | 2,4 s | 2,0 s |
| CLS | **0,177** | **0** |
| TBT | 0 ms | 0 ms |
| HTML na rede | 56 KB | **14 KB** (17 KB com o FAQ) |
| CSS render-blocking | 69 KB | **50 KB** |

> **O SEO já marcava 100 antes, e isso não queria dizer nada.** A categoria SEO do Lighthouse
> confere higiene (tem `<title>`, tem `description`, tem viewport, os links são rastreáveis) —
> ela não olha canônica ausente, Open Graph ausente, sitemap ausente ou hierarquia de títulos
> quebrada. A landing tinha os quatro problemas com nota cheia. É por isso que o trabalho de SEO
> abaixo é maior que o de performance, apesar de a nota não ter se mexido.

## Os dois bugs de produção que a medição revelou

Não eram "oportunidades de otimização": eram defeitos que já estavam no ar.

### B1 — o Vite embutia fontes em `data:` que a nossa própria CSP bloqueava

O `assetsInlineLimit` do Vite embute qualquer asset com menos de 4 KB no CSS. As fatias pequenas
do Fontsource (cirílico, vietnamita) caem abaixo disso, então **4 arquivos de fonte viravam
base64 dentro do CSS** — 18 KB, **26% de todo o CSS render-blocking** do projeto.

E o `font-src 'self'` da nossa CSP ([svelte.config.js](../web/svelte.config.js)) **bloqueava as
quatro**. O sintoma: peso que atrasa o primeiro paint de *toda* página do app, que nunca desenha
glifo nenhum, e que enche o console de violação de CSP a cada carregamento — o que derrubava a
nota de Boas Práticas em dois audits (`errors-in-console` e `inspector-issues`).

Conserto em [`vite.config.ts`](../web/vite.config.ts): `assetsInlineLimit` vira função e devolve
`false` para fonte. Como arquivo, a fatia sai do caminho crítico (baixa em paralelo, e só se o
texto pedir aquele alfabeto) e passa pelo `self`.

### B2 — o HTML do SSR saía sem compressão

O `adapter-node` pré-comprime no build (`.gz`/`.br`, servidos pelo sirv) **só os arquivos de
`_app/`**. O HTML é gerado por request e saía cru: 56 KB por visita, 42 KB de desperdício
medidos pelo Lighthouse.

Não havia camada na frente para consertar isso. É a mesma lição do HSTS na
[Onda 5](46-onda-5-producao.md): **a edge do Fly não comprime** — o `force_https` faz o redirect
e nada mais. Sem esta linha, todo visitante da landing baixava 4× mais HTML do que precisava.

Conserto em [`$lib/server/compress.ts`](../web/src/lib/server/compress.ts), chamado no fim do
`handle`. `CompressionStream` é padrão web e existe no Node desde a 18 — **sem dependência nova
e sem servidor customizado em volta do `build/handler.js`**, que é o caminho que a documentação
do adapter sugere. Por ser stream, o SSR em fatias continua fluindo.

Detalhes que o teste fixa:

* `Vary: accept-encoding` sai **comprimindo ou não** — a decisão dependeu do header do cliente,
  e sem o `Vary` um cache intermediário entrega a variante errada;
* `content-length` é apagado (o valor antigo faria o cliente truncar a leitura);
* `gzip;q=0` é recusa explícita (RFC 9110 §12.5.3) e é respeitada. O peso é comparado como
  **número**: `q=0`, `q=0.0` e `q=0.000` são a mesma recusa — a primeira versão comparava texto
  e deixava `q=0.0` passar. Quem pegou foi o teste, não a medição.

Brotli comprimiria ~15% melhor, mas o `CompressionStream` do Node 22 só aceita gzip/deflate
(medido). Trocar por `node:zlib` para ganhar isso custaria a compatibilidade do stream web.

## Performance — as outras duas frentes

### P1 — o CLS de 0,177 era 100% troca de fonte

O culpado apontado pelo Lighthouse era a seção do herói, e a causa, `Web font loaded`. O
`@font-face` só é descoberto **depois** que o CSS baixa e o layout casa um nó de texto com a
família: a página pintava na fonte de sistema e remontava a manchete depois, empurrando tudo
abaixo dela.

Um `<link rel="preload">` da fatia latina da Hanken no layout raiz **zerou o CLS** — de 0,177
para 0. Não foi preciso `size-adjust` nem métricas de fallback: com a fonte no ar junto do CSS,
o primeiro paint já sai na fonte certa e não há troca para compensar.

Duas armadilhas no caminho:

* **`crossorigin` é obrigatório mesmo em mesma origem.** Fonte é sempre buscada em modo CORS; sem
  o atributo o preload não casa com o pedido do CSS e o browser baixa o arquivo duas vezes.
* **A URL tem de ser a mesma com hash.** Por isso o import é
  `…/files/hanken-grotesk-latin-wght-normal.woff2?url` — o Vite deduplica o asset e devolve
  exatamente a URL que o `@font-face` do Fontsource vai pedir. Um caminho escrito à mão
  aqueceria um arquivo que ninguém pede.

### P2 — um round-trip à API em cada visita anônima

O `load` da raiz chama `loadMe`, que chamava `/api/auth/me` **sempre** — inclusive para quem
chega sem cookie de sessão. Como o `apiFetch` só identifica o usuário pelo `_api_key`, essa ida
volta 401 por construção: era latência pura no TTFB.

`loadMe` agora devolve `null` sem tocar na API quando não há cookie. Vale para as três páginas
que mais recebem visitante deslogado: `/`, `/entrar` e `/criar-conta`.

## SEO — o que não existia

### Tags de cabeçalho

Antes havia `<title>` e `<meta description>`. Foram acrescentados, com a canônica e a origem
vindas do servidor (dependem do `ORIGIN` do fly.toml, que o cliente não conhece):

* `<link rel="canonical">` — **a query é descartada**. Sem isso, cada `?utm_source=…` de campanha
  vira uma URL concorrente da mesma página no índice.
* Open Graph completo + Twitter `summary_large_image`, com imagem 1200×630.
* `theme-color` (o navy da marca, para o celular não abrir com faixa branca sobre o herói escuro).

O **título mudou**: era `Cinetra · a agenda que cuida da sua clínica` — bonito, e sem nenhum termo
que alguém digita na busca. Agora é `Cinetra · agenda e gestão para clínicas de fisioterapia`
(55 caracteres, cabe no corte de ~60). A manchete emocional não se perdeu: ela virou o `og:title`,
porque em card de rede social o leitor já veio pelo link, não por uma consulta.

### A imagem de compartilhamento

`static/og.png`, gerada por [`scripts/og-image.mjs`](../web/scripts/og-image.mjs) — script, e não
asset solto, para ser **reproduzível** quando a manchete ou a marca mudarem. Usa o Chromium que já
vem com o Playwright (devDependency) e a Hanken de `node_modules`: nenhuma dependência nova.

> GOTCHA que custou uma rodada: a página é montada por `setContent`, cuja origem é `about:blank`,
> e daí um `@font-face` apontando para `file://` é barrado por CORS **em silêncio** — o card sai
> em Arial e só se percebe olhando a imagem. A fonte vai embutida em base64. É o oposto exato da
> regra do site (B1), e pela mesma razão de sempre: ali há origem para cruzar, aqui não.

### O `<head>` público num componente só

As tags nasceram inline na landing e, quando `/entrar` e `/criar-conta` também precisaram delas,
viraram [`Seo.svelte`](../web/src/lib/components/Seo.svelte). São ~15 tags × 3 páginas: copiadas,
divergem calado — a que some é a que ninguém vê faltar, porque nada quebra. Só o card do WhatsApp
fica sem imagem e a canônica aponta para outro lugar.

`<svelte:head>` dentro de componente funciona (o SvelteKit iça o conteúdo para o `<head>` no SSR).
O JSON-LD **não** entrou: é específico da landing, e enfiá-lo ali obrigaria a passar um objeto que
só uma das três páginas usa.

`ogTitulo` é prop separada do `titulo` porque as duas frases têm públicos diferentes: quem vê o
`<title>` veio de uma consulta e precisa reconhecer o termo que digitou; quem vê o card já veio
pelo link e precisa da promessa. A landing manda a manchete; `/criar-conta` manda a oferta
("14 dias grátis na Cinetra, sem cartão de crédito"); `/entrar` não tem manchete e cai no título.

> GOTCHA do Svelte 5: `const imagem = \`${origem}/og.png\`` acende `state_referenced_locally` —
> `origem` é prop, e o `const` capturaria só o valor inicial. Vira `$derived`. O `svelte-check` é
> gate de CI no projeto, então warning não passa.

### Ícone de app e manifest

`apple-touch-icon.png` (180), `icon-192`, `icon-512`, `icon-maskable-512` e
`manifest.webmanifest`, todos gerados de **`favicon.svg`** por
[`scripts/icons.mjs`](../web/scripts/icons.mjs) — a mesma arte, para não existirem duas versões da
marca que divergem na próxima troca. Mesmo motor do card OG: o Chromium do Playwright, sem
dependência nova.

Três coisas que o formato impõe, e que um "exporta em 4 tamanhos" erra:

* **fundo opaco, sempre.** O iOS não respeita transparência em `apple-touch-icon`: PNG com alpha
  ganha fundo **preto** atrás da marca. O papel (`#F6F4EF`) é o único fundo em que os dois traços
  se leem — sobre o navy o traço azul quase some;
* **folga nas bordas**, porque iOS e Android recortam o quadrado no "squircle";
* **`maskable` é outro ícone, não o mesmo.** A área garantida é o círculo central de 80% do lado,
  onde cabe um quadrado de ~56%. Por isso o maskable leva a marca a 50% e o comum a 66% — reusar
  o comum como maskable é o que produz o logo cortado nos cantos.

O manifest sai **do mesmo script**, derivado da mesma lista que gera os arquivos: não há como
declarar um ícone que ninguém gerou, nem o contrário. Por isso não há teste — a invariante é da
construção, não de runtime.

`start_url` é `/agenda`, não `/`: quem instalou o app não quer abrir na página de vendas. Sem
sessão, a guarda do layout do `(app)` já manda para `/entrar`, e a regra não precisa ser repetida
no manifest.

Verificado pedindo ao próprio Chrome que o interpretasse (`Page.getAppManifest` via CDP, o mesmo
caminho do painel Application do DevTools): **`errors: []`**, `display: kStandalone`,
`startUrl: /agenda`, `themeColor rgba(33,42,55,1)`, três ícones resolvidos. O `.webmanifest` sai
com `application/manifest+json` (o `mrmime` do sirv já conhece a extensão) e a CSP não o barra —
`manifest-src` cai no `default-src 'self'`.

### `robots.txt` e `sitemap.xml`

O `robots.txt` era um arquivo em `static/` que liberava tudo e **não apontava sitemap**; sitemap
não existia. Os dois viraram rota (`+server.ts`), porque as duas precisam de URL **absoluta** e a
origem só se conhece em runtime — um arquivo estático teria de repetir o domínio à mão e passaria
a mentir no dia em que ele mudasse.

O `Disallow` das áreas privadas **não é segurança** (quem protege é a sessão): é orçamento de
rastreamento. Sem ele o robô gasta as visitas do site em redirect para `/entrar`.

`/entrar` e `/criar-conta` estão no sitemap, então ganharam `description` e canônica próprias —
página listada no sitemap sem canônica é convite a conteúdo duplicado, e `/entrar?erro=…` chega
com query. Um teste em [`seo.test.ts`](../web/src/lib/seo.test.ts) prova que as duas listas não se
contradizem (nada no sitemap pode estar no `Disallow`).

### Dados estruturados

JSON-LD com `Organization`, `WebSite` e `SoftwareApplication` (com `offers` e `featureList`).

> **Decisão: sem `aggregateRating` e sem `Review`.** A página exibe "4,9/5 avaliação das clínicas"
> e um depoimento assinado. Publicar isso como dado estruturado seria declarar avaliação agregada
> sem review verificável por trás — a política de rich results do Google trata como spam
> estrutural, e a punição atinge o **site inteiro**, não só o trecho. Fica de fora enquanto for
> texto ilustrativo. Os preços do JSON-LD espelham o que a página mostra ao carregar (cobrança
> anual, o padrão do toggle): dado estruturado que discorda do preço visível é motivo de ação
> manual.

### Semântica

* Os três títulos das "dores" eram `<div>` de 26px. Viraram `<h3>` — são as subseções do `<h2>`
  da seção, e como `div` o índice via um bloco grande seguido de texto solto, sem saber que ali
  começava assunto novo. Mesma coisa nos nomes dos planos.
* `<main id="conteudo">` (a página não tinha landmark nenhum) + atalho "pular para o conteúdo".
* `<nav aria-label>` e nome acessível no link do logo.

Um teste em [`page.svelte.test.ts`](../web/src/routes/page.svelte.test.ts) fixa a hierarquia:
um só `h1`, e nenhum salto de nível.

## A seção de dúvidas

Acrescentada logo depois — entre os planos e o último CTA, que é onde a objeção aparece.

### Correção: FAQ **não** rende mais rich result para nós

A primeira versão deste documento listava a seção como "o maior ganho de SEO ainda disponível
(ocupa espaço em rich results)". **Isso está errado desde agosto de 2023**, quando o Google
restringiu o rich result de FAQ a sites governamentais e de saúde reconhecidamente autoritativos.
Uma landing de SaaS não vai render a caixinha sanfonada no resultado da busca, e planejar em cima
disso é planejar em cima de uma coisa que não existe mais.

O que a seção **de fato** entrega:

* **texto que responde consulta de cauda longa** ("software fisioterapia LGPD", "migrar planilha
  clínica") — hoje a página inteira tinha ~600 palavras de copy publicitária e zero de resposta;
* **objeção respondida antes do formulário** — é ganho de conversão, não de posição;
* **o formato que os rastreadores de resposta de IA citam** — pergunta seguida de resposta curta.

O `FAQPage` no JSON-LD ficou mesmo assim: é dado correto, custa ~1 KB e outros consumidores leem.
Só não se espera rich result do Google por ele.

### Fonte única

As 8 perguntas moram em `FAQ`, em [`$lib/seo.ts`](../web/src/lib/seo.ts), e o **mesmo array**
desenha a seção e monta o `FAQPage`. Dado estruturado que não bate com o texto visível é motivo de
ação manual — e a maneira de duas listas divergirem é existirem duas listas. Um teste compara as
duas ponta a ponta.

### `<details>` nativo, não sanfona de JavaScript

Funciona sem hidratar, o teclado já sabe operar (verificado ao vivo: `Tab` + `Enter` abre), o
buscador lê a resposta mesmo com o item fechado e não há altura a reservar — logo, nenhum risco de
reintroduzir o CLS que esta entrega zerou. O CSS só troca o marcador padrão por um "+" que gira e
vira "−"; o foco envolve a linha inteira, porque o alvo do teclado é o `summary` todo.

Dois ajustes vieram da captura no celular, não do código:

* `text-wrap: balance` (o padrão das manchetes da página) deixava "Como funciona a / confirmação de
  sessão?" com a primeira linha pela metade. Numa lista alinhada à esquerda o certo é `pretty`:
  enche a linha e só evita a órfã;
* o recuo fixo de 42px à direita do parágrafo comia 13% da coluna a 412px.

### Centrada, e o que isso obrigou a mudar

A seção nasceu alinhada à esquerda e foi centrada na revisão seguinte: ela fecha a página logo
depois dos planos, que já são centrados, e as duas falando com alinhamentos diferentes brigavam.

Centrar o **bloco** não é centrar o **texto**: pergunta e resposta seguem alinhadas à esquerda,
porque texto corrido centrado obriga o olho a procurar o início de cada linha.

O detalhe que a centralização revelou: o parágrafo tinha `max-width: 74ch`, menor que a coluna.
Alinhado à esquerda isso passava; dentro de um bloco centrado virava um vão à direita que parece
erro de alinhamento. A coluna caiu de 860px para **680px — a mesma largura do cabeçalho** — e o
teto em `ch` saiu: quem limita a medida passou a ser o container, que já dá ~76 caracteres.

### As correções de conteúdo

Duas respostas estavam **erradas sobre o produto**, e uma delas era erro meu de fato, não de
redação:

* **permissões.** Dizia que "a recepção agenda sem precisar abrir dado clínico". É falso:
  [`Patient`](../api/lib/api/records/patient.ex) não tem `field_policies` nenhuma e a policy de
  leitura autoriza **qualquer papel** da clínica, então a recepção abre a ficha inteira — como
  precisa, para receber quem chega. O mesmo vale para anexo (`@papeis [:owner, :admin, :recepcao]`).
  Quem tem recorte é o **profissional**, por `OwnAgendaOnly` (A7/D1): só a própria agenda.
* **LGPD.** Dizia que "toda **leitura** e alteração de dado de paciente entra numa trilha de
  auditoria". A leitura não entra: o AshPaperTrail versiona **escrita**. O que é auditado na
  leitura é a abertura de anexo (`:visualizou`, [doc 51](51-ficha-anexos-e-storage.md)). Reescrita
  para descrever o que existe. Uma afirmação falsa sobre conformidade numa página comercial é o
  pior lugar possível para um detalhe errado passar.

Vale a lição de método: as duas passaram por já **soarem** plausíveis. O que as pegou foi abrir a
policy e o mixin, não reler o texto.

### Sem o mock flutuando

O card de agenda da seção "Recurso · Agenda" subia e descia sem parar (`cnFloat`, 7s infinitos),
do lado de um texto que a pessoa está lendo. Removido a pedido.

Duas coisas saíram junto, porque animação inline não deixa rastro que ferramenta nenhuma varra:

* o `<div>` que existia **só** para carregar o `animation:` virou invólucro vazio; o card passou a
  ser o próprio item do grid;
* a `@keyframes cnFloat` ficou órfã. O Tailwind não lê valor de atributo `style`, então nenhum
  passe de CSS não-usado a removeria — keyframe morto é peso que só sai à mão.

Verificado ao vivo em vez de por inspeção: amostrei a posição Y do card oito vezes ao longo de
7,2s (um ciclo inteiro da animação antiga). **Variação de 0px**, e `animation-name: none` no card
e no pai.

Sobram cinco animações infinitas na página (`cnBlob` ×4, `cnBreathe`, `cnScrollcue`), todas em
elementos decorativos de fundo e todas já respeitando `prefers-reduced-motion`.

### Sem travessão

Preferência de escrita do projeto: a copy do FAQ não usa travessão. Os três que existiam viraram
vírgula ou ponto-e-vírgula, e o `aria-label` do logo e o `og:image:alt` acompanharam. Virou
**teste** (`seo.test.ts`) porque é o tipo de coisa que volta sozinha na próxima pergunta que
alguém acrescentar. O resto da copy da landing, que vem do protótipo, já não tinha nenhum.

### ⚠️ Três respostas são promessa comercial, não descrição do que existe

Decisão do produto em 2026-07-27, tomada com o conflito na mesa. **Precisam de confirmação antes de
a página ir ao ar**, e estão marcadas no comentário de `FAQ`:

| Resposta | O que o código diz hoje |
| --- | --- |
| `migracao` — "você envia a planilha e nós importamos" | **Não existe importador nenhum.** A resposta promete serviço assistido, que é trabalho humano a combinar |
| `cancelar` — "sem multa, exporta os dados antes de sair" | **Não existe cobrança implementada.** Nem assinatura, nem exportação |
| `confirmacao` — "WhatsApp e e-mail" | O [doc 52](52-comunicacao-com-o-paciente.md) põe o WhatsApp na **fase 2**; a fase 1 é e-mail via Resend |

As outras cinco (instalação, LGPD, permissões, pacotes, multi-unidade) são verificáveis contra o
código e podem ir como estão.

A resposta de cancelamento **não inventa prazo de guarda** de propósito: o
[doc 06 §2.4](06-seguranca-e-lgpd.md) manda não hardcodar prazo antes de o jurídico confirmar qual
resolução do COFFITO se aplica. Ela diz que o prazo existe e que a clínica será orientada — o que é
verdade — sem cravar número.

### De quebra

A lista do plano Profissional dizia **"Prontuário do paciente"**. O prontuário é v2
([doc 08](08-roadmap.md), Fatia 6); o que a v1 entrega, e o que a tela mostra, é a **ficha**.
Corrigido junto, porque o FAQ responde sobre a mesma coisa e as duas não podiam discordar.

## Acessibilidade — o contraste

O axe reprovou **21 nós**; auditando à mão o resto da paleta, achei **mais 3 que ele havia
pulado** (marca como "incompleto" quando não consegue resolver o fundo, e o Lighthouse não conta
isso como falha). Os piores: `#B4AE9F` sobre papel a **2,01:1**, o rodapé a 2,45:1, o "!" da
trilha a 1,85:1.

A paleta quente do protótipo tinha **cinco** tons de neutro para texto secundário, todos entre
2,0 e 4,4:1. Viraram **um** — `#696356`, que passa em papel (5,43), em card branco (5,97) e no
fundo dos planos (5,14). Não dá para ter um "quase apagado" acessível sobre fundo claro: a
hierarquia visual desses textos passa a ser **tamanho e peso**, não contraste. É a resposta padrão
de design acessível, e a comparação das capturas antes/depois mostra que a página não perdeu o ar.

| De | Para | Onde |
| --- | --- | --- |
| `#B4AE9F` `#A39D8F` `#9A9486` `#8A8577` `#736E63` | `#696356` | todo o neutro quente de texto |
| `#8A929B` `#77828C` `#9AA3AC` | `#697077` | cinza frio dos mocks de produto |
| `#4E7468` | `#4A6E62` | eyebrows e horas nos mocks |
| `#243c34` | `#1E332C` | legendas sobre a faixa sálvia |
| `#6A6456` | `#5E594C` | aba inativa do toggle de planos |
| fundo `#7FA59A` | `#4A6E62` | avatar de iniciais (branco sobre sálvia dava 2,71) |
| `#fff` sobre âmbar | `#4A3B0C` | o "!" da trilha de sessões |
| `stroke #B98A1E` | `#8A6A14` | ícone do alerta de renovação (não-texto, alvo 3:1) |

E o toggle de cobrança ganhou `role="group"` + `aria-pressed`: sem isso o leitor de tela anunciava
"Mensal, botão / Anual, botão" **sem dizer qual estava valendo** — a única pista era a cor do fundo.

## Verificação

* `npm run coverage` — **1592 testes, 157 arquivos, 0 falhas**; 90,58% statements / 76,1% branches
  / 89,64% functions / 91,34% lines, acima do gate ([doc 15](15-gate-de-cobertura-e-ci.md)).
* Lighthouse ×5 sobre o build de produção: **mediana 99 / 100 / 100 / 100**, CLS 0 nas cinco.
  A seção de dúvidas não custou nota (+11 KB de HTML cru viram +2,6 KB depois do gzip, e o
  `<details>` não gera layout shift).

  > Uma das cinco execuções marcou 91. Não é regressão: ela veio com 6,6s de trabalho de
  > main-thread e 260ms de TBT contra ~2,6s e ~10ms das outras — contenção da máquina, que rodava
  > o container e a suíte ao mesmo tempo. **Rodada única de Lighthouse não é medição**; é por isso
  > que todos os números deste documento saem de 3 a 5 execuções, e não da primeira que apareceu.
* `npm run check` — 0 erros, 0 avisos.
* Capturas em desktop e mobile das três seções mais alteradas, para conferir que o contraste não
  achatou o desenho.

> Nota de método: o teste `DayGrid.svelte.test.ts` falhou de forma intermitente em duas execuções
> da suíte cheia e passou sozinho e na execução limpa. É flakiness sob carga (o container roda o
> dev server ao mesmo tempo), não regressão desta entrega — mas fica registrado.

## O que ficou de fora, e por quê

* **`aggregateRating`/`Review` no JSON-LD** — só quando houver review verificável. Ver acima.
* **Brotli.** Ver B2.
* **Tirar o CSS do app da landing.** Os 50 KB render-blocking são o design system inteiro, porque
  `app.css` mora no layout raiz. Movê-lo para o layout do `(app)` cortaria mais uns 30 KB da
  landing, mas mexe em todas as telas autenticadas e nas de auth por um ganho que, comprimido
  (~16 KB), não aparece na nota. Não vale o risco agora.
* **`sameAs` na `Organization`** — são os perfis sociais, que ainda não existem. Apontar para um
  perfil que não é da empresa é pior do que não declarar dono nenhum.
* **Card próprio para `/criar-conta`.** Hoje as três páginas compartilham `og.png`. Um card com a
  oferta ("14 dias grátis, sem cartão") converteria melhor no destino dos anúncios — o `og:title`
  já diz isso, a imagem ainda não.
* **`theme-color` no shell interno.** As três páginas públicas passaram a ter (é do `Seo.svelte`),
  mas o layout do `(app)` não: lá há tema claro/escuro, e um navy fixo brigaria com o escuro.
* **`placeholder` dos formulários de auth** (`.cn-root input::placeholder`, `#B0AA9C` sobre branco
  = 2,31:1). É a mesma folha, mas é tela de autenticação, não a landing — conserto de uma linha
  para quando alguém mexer ali.
* **Domínio próprio.** A canônica, o sitemap e o `og:image` saem todos do `ORIGIN`
  (`web/fly.toml`), hoje `https://movimento-web.fly.dev`. **Quando o domínio da Cinetra entrar, é
  só trocar o `ORIGIN`** — nenhuma URL está escrita à mão em lugar nenhum.
