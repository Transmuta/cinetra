defmodule Api.EmailLayout do
  @moduledoc """
  O HTML dos e-mails — a moldura que os **dois** planos de e-mail do projeto compartilham.

  Há dois modelos, e eles não são o mesmo desenho com outra cor:

    * **conta** (`Api.Accounts.Emails`) — quem recebe é usuário do sistema, o remetente é a
      Cinetra e o topo é a nossa marca. Cabeçalho com o logo e nada mais;
    * **paciente** (`Api.Messaging.PatientEmails`) — quem recebe não tem login e não tem relação
      com a Cinetra: tem com a **clínica**. Por isso o topo é o nome dela, e a Cinetra aparece só
      no rodapé, como quem entrega. É o mesmo §9.1.4 que obriga o nome da clínica na primeira
      linha do WhatsApp, aplicado ao canal que tem cabeçalho.

  O que os dois compartilham é a moldura: a paleta, o cartão, o botão, a régua de tipografia. Ela
  mora aqui inteira porque duas cópias divergem na primeira correção de cor — e divergência entre
  e-mails da mesma marca é invisível em teste e visível na caixa de entrada.

  ## Os dois motores que decidem o desenho

  Um e-mail não roda num navegador. Os dois que importam para nós:

    * **Outlook no Windows** (2007 em diante) renderiza com o motor do **Word**. Sem flex, sem
      grid, sem `float`, sem `background-image`, e — a pegadinha que estraga botão — **sem
      `padding` em `<a>`** e sem `display:block` nele. Por isso todo espaçamento mora em `<td>`,
      que o Word respeita, e o botão tem uma versão em VML só para ele (ver `botao/2`);
    * **Gmail** suporta `<style>` e media query desde 2016 — o que ele **não** suporta é o app do
      Gmail lendo conta de outro provedor (o "GANGA"), que descarta a folha inteira. É por isso
      que o `<style>` daqui só carrega melhorias (mobile, reset de detecção do iOS) e **todo
      estilo que precisa valer está inline**, no atributo de cada elemento.

  Fora esses dois, a base — tabela aninhada, largura fixa de 600px, estilo inline, cor em
  atributo `bgcolor` além do CSS — é o que faz Apple Mail, Yahoo, Outlook.com, Thunderbird e
  webmail de provedor pequeno renderizarem igual.

  ## O e-mail sai em duas partes, e a de texto não é enfeite

  Todo e-mail daqui vai com `text_body` **e** `html_body`. A parte de texto é o que aparece em
  cliente que não renderiza HTML, é o que o filtro de spam lê quando desconfia de uma mensagem só
  de imagem, e é o que sobra quando o usuário desliga o HTML. Ela continua sendo escrita à mão em
  cada e-mail — não é o HTML com as tags raspadas, que produziria um texto sem parágrafo e com o
  link no meio da frase.

  ## O logo é servido pelo web, e por isso o `alt` importa

  `data:` em `<img>` é bloqueado pelo Gmail e `cid:` depende do adapter repassar anexo inline — o
  que o Resend faz por um campo próprio que o Swoosh não expõe. Sobra URL hospedada, e a que já
  existe é a do próprio app (`Api.web_app_url/0`), que é https em produção e não põe asset nosso
  em serviço de terceiro.

  Só que **imagem bloqueada é o estado padrão** de boa parte das caixas: o `alt` do logo vai
  estilizado (branco, bold, espaçado) justamente para que o cabeçalho continue dizendo "Cinetra"
  quando a imagem não carregar. É o mesmo motivo de nenhum texto do corpo viver dentro de imagem.

  ## Tema escuro: ou a gente escolhe as cores, ou o cliente escolhe por nós

  Um e-mail claro numa caixa em tema escuro não é deixado em paz. Cada família de cliente faz uma
  coisa diferente, e as três precisam de resposta própria:

    * **Apple Mail / iOS** lê `color-scheme` e `prefers-color-scheme`. É o único grupo que aceita
      "não inverta" — mas aceitar isso é entregar um cartão branco ofuscante no meio de uma caixa
      escura. Aqui a gente declara `light dark` e **entrega uma paleta escura de verdade**;
    * **Outlook.com** (web e app) ignora media query: ele repinta sozinho e marca cada elemento
      que mexeu com `data-ogsc` (cor) e `data-ogsb` (fundo). Por isso as mesmas regras saem duas
      vezes — uma na media query, outra prefixada por esses atributos;
    * **Gmail no telefone** inverte tudo por algoritmo e não oferece gancho nenhum. Contra ele não
      há CSS: o que dá para fazer é não piorar (ver o logo, abaixo).

  Como a folha é opcional (o `<style>` some no app do Gmail com conta de outro provedor) e o
  estilo que precisa valer é inline, **toda regra escura vem com `!important`** — sem isso o
  atributo `style` do elemento ganha e nada muda. E é por isso que cada elemento colorido carrega
  uma classe `cn-*`: a classe é o único gancho que a folha tem para alcançar o inline.

  **O cabeçalho fica `#212A37` também no escuro**, e isso é deliberado: o PNG do logo tem essa cor
  como placa embutida (é RGB, sem canal alfa). Escurecer a faixa faria aparecer um retângulo
  visível em volta do logo — que é justamente o defeito que o Gmail produz sozinho ao clarear a
  faixa e deixar a imagem intacta. Enquanto o asset não tiver fundo transparente, a faixa não se
  mexe.
  """

  # A paleta, num lugar só. Os nomes descrevem o papel, não a cor: trocar o verde da marca é
  # editar uma linha, e não caçar `#7FA59A` por seis arquivos.
  @fundo "#EFEDE7"
  @cartao "#FBFAF6"
  @borda "#E2DED3"
  @escuro "#212A37"
  @sage "#7FA59A"
  @sage_escuro "#4E7468"
  @texto "#5D5749"
  @texto_alt "#3D3A32"
  @texto_fraco "#6B6558"
  @linha "#E4E0D5"
  @linha_forte "#E0DACC"
  @rodape_fundo "#F1EFE8"
  @caixa_fundo "#F1F5F3"
  @caixa_borda "#DCE6E1"
  @caixa_texto "#3F5A50"
  @caixa_link "#28453B"
  @claro "#C3CBD2"

  # A mesma paleta lida no escuro. Não é a de cima invertida: `@escuro` é fundo de faixa **e** cor
  # de título, e as duas leituras vão para lados opostos aqui — a faixa continua escura, o título
  # vira quase branco. Por isso os nomes daqui são os do papel no escuro, não o par de cada cor.
  @fundo_esc "#0E1116"
  @cartao_esc "#171D25"
  @borda_esc "#2B3441"
  # A faixa do cabeçalho **não muda**: o PNG do logo tem esta cor de placa embutida (ver o
  # moduledoc). Mexer nela é fazer aparecer o retângulo em volta do logo.
  @cabecalho_esc @escuro
  @titulo_esc "#F1F3F6"
  @texto_esc "#B7BDC6"
  @texto_alt_esc "#D3D8DE"
  @texto_fraco_esc "#8F97A2"
  # O verde da marca precisa clarear para continuar legível: `#4E7468` sobre `#171D25` fica em
  # ~1,9:1, abaixo de qualquer piso de contraste.
  @sage_esc "#9BC4B6"
  @linha_esc "#2B3441"
  @rodape_fundo_esc "#12171E"
  @caixa_fundo_esc "#16211E"
  @caixa_borda_esc "#2B3A34"
  @caixa_texto_esc "#B4C6BF"
  # O botão inverte o par: no claro é marinho com texto branco; no escuro, marinho sobre cartão
  # escuro sumiria, então ele vira o verde da marca com texto escuro.
  @botao_fundo_esc @sage
  @botao_texto_esc "#101A16"
  @claro_esc "#A7B1BC"

  # Arial e nada de webfont: o Word não carrega `@font-face`, e uma fonte que só metade das
  # caixas enxerga produz dois e-mails diferentes. A pilha é a mesma do desenho.
  @fonte "Arial,Helvetica,sans-serif"

  # Os atributos que **toda** tabela repete. Um `<table>` sem eles ganha espaçamento do próprio
  # cliente (o Word insere gaps entre células), e `role="presentation"` é o que impede o leitor
  # de tela de anunciar "tabela de 3 colunas" para o que é só diagramação.
  @tabela ~s(role="presentation" cellpadding="0" cellspacing="0" border="0")

  # `border-collapse` e os dois `mso-table-*` andam juntos e valem para toda tabela: sem o
  # primeiro, borda de célula vizinha duplica; sem os outros dois, o Word acrescenta ~2pt de cada
  # lado da tabela e o cartão de 600px passa a não caber na coluna.
  @reset_tabela "border-collapse:collapse;mso-table-lspace:0pt;mso-table-rspace:0pt;"

  # A largura útil dentro do cartão: 600 do cartão menos os 40 de padding de cada lado. Existe
  # como número porque o VML do botão (o único lugar que não sabe medir sozinho) precisa dela.
  @largura_conteudo 520

  # 22 de entrelinha + 17 de padding em cima e embaixo. Mesma conta que o `botao/2` faz em CSS —
  # e é por isso que os três números moram aqui, e não espalhados na string.
  @altura_botao 56
  @raio_botao 12

  # O rabicho invisível do preheader. Sem ele o cliente completa a linha de prévia com o que vem
  # depois no corpo — e o que vem depois é "Olá, Maria!", que não acrescenta nada a quem já leu o
  # assunto. A sequência é zero-width joiner + espaço rígido, que nenhum cliente renderiza.
  @espacador_preheader String.duplicate("&#847;&zwnj;&nbsp;", 20)

  @doc """
  O documento inteiro: `<html>`, cartão e os blocos que vierem em `:blocos`.

  `:preheader` é a linha que o cliente mostra ao lado do assunto na lista de mensagens. Vai
  escondida no topo do corpo porque, sem ela, o cliente escolhe sozinho — e escolhe a primeira
  frase visível, que costuma ser "Olá!".
  """
  def documento(opts) do
    """
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" lang="pt-BR">
    <head>
    <meta charset="utf-8" />
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <meta name="x-apple-disable-message-reformatting" />
    <meta name="format-detection" content="telephone=no,date=no,address=no,email=no" />
    <meta name="color-scheme" content="light dark" />
    <meta name="supported-color-schemes" content="light dark" />
    <title>#{escapar(opts[:titulo])}</title>
    <!--[if mso]>
    <xml><o:OfficeDocumentSettings><o:AllowPNG/><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml>
    <![endif]-->
    <style>
      /* Só melhorias: o que precisa valer está inline (ver o moduledoc — o app do Gmail com conta
         de outro provedor descarta esta folha inteira). */
      :root{color-scheme:light dark;supported-color-schemes:light dark}
      body{margin:0!important;padding:0!important;width:100%!important;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%}
      table{#{@reset_tabela}}
      img{border:0;outline:none;text-decoration:none;-ms-interpolation-mode:bicubic}
      /* O iOS transforma data, hora e telefone em link azul sublinhado por conta própria. */
      a[x-apple-data-detectors]{color:inherit!important;text-decoration:none!important;font-size:inherit!important;font-family:inherit!important;font-weight:inherit!important;line-height:inherit!important}
      @media only screen and (max-width:620px){
        .cn-wrap{width:100%!important}
        .cn-pad{padding-left:22px!important;padding-right:22px!important}
        .cn-h1{font-size:26px!important;line-height:32px!important}
        .cn-stack,.cn-stack td{display:block!important;width:100%!important}
      }
    #{css_escuro()}
    </style>
    </head>
    <body class="cn-body" bgcolor="#{@fundo}" style="margin:0;padding:0;width:100%;background-color:#{@fundo};">
    <div class="cn-pre" style="display:none;font-size:1px;color:#{@fundo};line-height:1px;mso-line-height-rule:exactly;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">#{escapar(opts[:preheader])}#{@espacador_preheader}</div>
    <table #{@tabela} class="cn-body" width="100%" bgcolor="#{@fundo}" style="#{@reset_tabela}background-color:#{@fundo};">
    <tr><td align="center" style="padding:28px 12px;">
      <table #{@tabela} width="600" class="cn-wrap cn-card" bgcolor="#{@cartao}" style="#{@reset_tabela}width:600px;max-width:600px;background-color:#{@cartao};border-radius:16px;overflow:hidden;border:1px solid #{@borda};">
    #{opts[:blocos]}
      </table>
    </td></tr>
    </table>
    </body>
    </html>
    """
  end

  # O tema escuro inteiro, uma classe por papel. A lista existe **uma vez** e é impressa duas
  # (media query + Outlook.com) porque as duas cópias divergiriam na primeira correção de cor — e
  # divergência entre os dois é invisível aqui e visível só na caixa de quem usa Outlook.com.
  #
  # Toda declaração leva `!important`: a folha está competindo com o atributo `style` do próprio
  # elemento, e sem isso o inline ganha e a media query não faz nada.
  defp regras_escuras do
    [
      {".cn-body", "background-color:#{@fundo_esc}!important"},
      {".cn-pre", "color:#{@fundo_esc}!important"},
      {".cn-card",
       "background-color:#{@cartao_esc}!important;border-color:#{@borda_esc}!important"},
      {".cn-head", "background-color:#{@cabecalho_esc}!important"},
      {".cn-on-head", "color:#FFFFFF!important"},
      {".cn-on-head-soft", "color:#{@claro_esc}!important"},
      {".cn-title", "color:#{@titulo_esc}!important"},
      {".cn-text", "color:#{@texto_esc}!important"},
      {".cn-text-alt", "color:#{@texto_alt_esc}!important"},
      {".cn-muted", "color:#{@texto_fraco_esc}!important"},
      {".cn-strong", "color:#{@titulo_esc}!important"},
      {".cn-accent", "color:#{@sage_esc}!important"},
      # O filete verde é o único que fica igual nos dois temas — e está na lista para dizer que
      # isso foi decidido, não esquecido.
      {".cn-sage", "background-color:#{@sage}!important"},
      {".cn-rule", "border-color:#{@linha_esc}!important"},
      {".cn-btn", "background-color:#{@botao_fundo_esc}!important"},
      {".cn-btn-a", "color:#{@botao_texto_esc}!important"},
      {".cn-box",
       "background-color:#{@caixa_fundo_esc}!important;border-color:#{@caixa_borda_esc}!important"},
      {".cn-box-text", "color:#{@caixa_texto_esc}!important"},
      {".cn-box-a", "color:#{@sage_esc}!important"},
      {".cn-foot",
       "background-color:#{@rodape_fundo_esc}!important;border-color:#{@borda_esc}!important"}
    ]
  end

  defp css_escuro do
    """
      @media (prefers-color-scheme:dark){
    #{Enum.map_join(regras_escuras(), "\n", fn {sel, dec} -> "        #{sel}{#{dec}}" end)}
      }
      /* O Outlook.com não aplica media query: ele repinta e marca o que mexeu. */
    #{Enum.map_join(regras_escuras(), "\n", fn {sel, dec} -> "      [data-ogsc] #{sel},[data-ogsb] #{sel}{#{dec}}" end)}\
    """
  end

  @doc """
  O cabeçalho dos e-mails de **conta**: o logo, e só.

  Sem assinatura de marca embaixo e com respiro vertical curto — quem recebe já sabe o que é a
  Cinetra (tem conta), e o que ele veio fazer aqui está no corpo, não no topo.
  """
  def cabecalho_marca do
    """
        <tr>
          <td class="cn-pad cn-head" bgcolor="#{@escuro}" style="background-color:#{@escuro};padding:22px 40px;" align="center">
            <img src="#{logo_url()}" alt="Cinetra" class="cn-on-head" width="150" height="44" style="display:block;border:0;outline:none;text-decoration:none;-ms-interpolation-mode:bicubic;font-family:#{@fonte};font-size:22px;line-height:44px;mso-line-height-rule:exactly;letter-spacing:5px;font-weight:bold;color:#FFFFFF;" />
          </td>
        </tr>
    """
  end

  @doc """
  O cabeçalho dos e-mails ao **paciente**: a clínica em destaque.

  Endereço e CNPJ ficam de fora porque não viajam em `Api.Messaging.Dispatch.vars/3` — e o que
  não está nas `vars` gravadas não pode entrar aqui sem mentir sobre o histórico: a mensagem é
  renderizada a partir do que foi congelado no envio, não do que a ficha da clínica diz hoje.
  """
  def cabecalho_clinica(nome, telefone) do
    """
        <tr>
          <td class="cn-pad cn-head" bgcolor="#{@escuro}" style="background-color:#{@escuro};padding:32px 40px 30px 40px;">
            <table #{@tabela} width="100%" style="#{@reset_tabela}">
              <tr><td class="cn-h1 cn-on-head" style="font-family:#{@fonte};font-size:28px;line-height:34px;letter-spacing:-0.5px;mso-line-height-rule:exactly;font-weight:bold;color:#FFFFFF;padding-bottom:14px;">#{escapar(nome)}</td></tr>
              <tr><td#{if telefone_visivel?(telefone), do: ~s( style="padding-bottom:14px;")}><table #{@tabela} width="52" style="#{@reset_tabela}"><tr><td class="cn-sage" height="3" bgcolor="#{@sage}" style="height:3px;line-height:3px;font-size:0;mso-line-height-rule:exactly;border-radius:2px;">&nbsp;</td></tr></table></td></tr>
    #{linha_telefone(telefone)}
            </table>
          </td>
        </tr>
    """
  end

  defp linha_telefone(telefone) do
    if telefone_visivel?(telefone) do
      """
              <tr><td class="cn-on-head-soft" style="font-family:#{@fonte};font-size:14px;line-height:22px;mso-line-height-rule:exactly;color:#{@claro};">#{escapar(telefone)}</td></tr>
      """
    else
      ""
    end
  end

  defp telefone_visivel?(telefone), do: is_binary(telefone) and String.trim(telefone) != ""

  @doc "Título e primeiro parágrafo — a abertura de todo e-mail."
  def abertura(titulo, paragrafo) do
    """
        <tr>
          <td class="cn-pad" style="padding:40px 40px 8px 40px;">
            <table #{@tabela} width="100%" style="#{@reset_tabela}">
              <tr><td class="cn-h1 cn-title" style="font-family:#{@fonte};font-size:30px;line-height:38px;letter-spacing:-0.5px;mso-line-height-rule:exactly;font-weight:bold;color:#{@escuro};padding-bottom:16px;">#{escapar(titulo)}</td></tr>
              <tr><td class="cn-text" style="font-family:#{@fonte};font-size:16px;line-height:26px;mso-line-height-rule:exactly;color:#{@texto};padding-bottom:28px;">#{paragrafo}</td></tr>
            </table>
          </td>
        </tr>
    """
  end

  @doc """
  O botão principal. Um por e-mail — dois botões é uma pergunta a mais do que a pessoa veio
  responder.

  ## Por que ele é escrito duas vezes

  Porque o Word (motor do Outlook no Windows) **ignora `padding` e `display:block` em `<a>`**.
  Um botão feito do jeito normal chega lá como um texto colado nas bordas de um retângulo
  colorido — clicável só na palavra, e sem respiro nenhum.

  Então:

    * **Outlook** recebe um `v:roundrect` (VML, a linguagem de desenho do Office). Ele dá o canto
      arredondado, a altura certa e — o que importa — a área clicável inteira. Precisa de medida
      em pixel, e é por isso que `@largura_conteudo` e `@altura_botao` existem como número: o VML
      não sabe medir sozinho;
    * **todo o resto** recebe a tabela normal, com o padding no `<td>` (que o Word também
      respeitaria) e o `<a>` como `inline-block`.

  Os dois blocos se excluem por comentário condicional, então nunca aparecem juntos. O
  `downlevel-revealed` (`<!--[if !mso]><!-- -->`) é o que esconde o segundo do Outlook: comentário
  condicional comum esconderia dos outros clientes, que é o contrário do que se quer.
  """
  def botao(url, rotulo) do
    url = escapar(url)
    rotulo = escapar(rotulo)

    """
        <tr>
          <td class="cn-pad" style="padding:0 40px 22px 40px;" align="center">
            <!--[if mso]>
            <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="#{url}" style="height:#{@altura_botao}px;v-text-anchor:middle;width:#{@largura_conteudo}px;" arcsize="#{round(@raio_botao / @altura_botao * 100)}%" stroke="f" fillcolor="#{@escuro}">
              <w:anchorlock/>
              <center style="color:#FFFFFF;font-family:#{@fonte};font-size:16px;font-weight:bold;">#{rotulo}</center>
            </v:roundrect>
            <![endif]-->
            <!--[if !mso]><!-- -->
            <table #{@tabela} width="100%" style="#{@reset_tabela}">
              <tr>
                <td class="cn-btn" align="center" bgcolor="#{@escuro}" style="background-color:#{@escuro};border-radius:#{@raio_botao}px;padding:17px 24px;">
                  <a href="#{url}" class="cn-btn-a" style="display:inline-block;font-family:#{@fonte};font-size:16px;line-height:22px;mso-line-height-rule:exactly;font-weight:bold;color:#FFFFFF;text-decoration:none;">#{rotulo}</a>
                </td>
              </tr>
            </table>
            <!--<![endif]-->
          </td>
        </tr>
    """
  end

  @doc "A linha pequena e centrada abaixo do botão (validade do link, aviso curto)."
  def nota(texto) do
    """
        <tr>
          <td class="cn-pad" style="padding:0 40px 28px 40px;" align="center">
            <table #{@tabela} width="100%" style="#{@reset_tabela}">
              <tr><td class="cn-muted" align="center" style="font-family:#{@fonte};font-size:13px;line-height:20px;mso-line-height-rule:exactly;color:#{@texto_fraco};">#{escapar(texto)}</td></tr>
            </table>
          </td>
        </tr>
    """
  end

  @doc """
  A caixa com a URL em texto, para quando o botão não funciona.

  Cliente que remove `<a>`, webmail corporativo que reescreve link e leitor que abre o e-mail no
  celular e quer copiar para o computador — os três só têm saída se a URL estiver escrita.

  A URL é uma palavra só de ~100 caracteres, e é o tipo de coisa que **alarga a tabela** num
  cliente que não souber quebrá-la — o cartão de 600px vira 900px e o e-mail inteiro sai torto.
  Daí o par `word-break` (padrão, para os navegadores) e `word-wrap` (que é a propriedade que o
  Word entende), mais o `table-layout:fixed`, que impede a tabela de crescer com o conteúdo.
  """
  def caixa_url(url) do
    """
        <tr>
          <td class="cn-pad" style="padding:0 40px 28px 40px;">
            <table #{@tabela} class="cn-box" width="100%" bgcolor="#{@caixa_fundo}" style="#{@reset_tabela}table-layout:fixed;background-color:#{@caixa_fundo};border:1px solid #{@caixa_borda};border-radius:10px;">
              <tr>
                <td class="cn-box-text" style="padding:16px 18px;font-family:#{@fonte};font-size:13px;line-height:21px;mso-line-height-rule:exactly;color:#{@caixa_texto};word-break:break-all;word-wrap:break-word;">
                  O botão não funcionou? Copie e cole este endereço no navegador:<br />
                  <a href="#{escapar(url)}" class="cn-box-a" style="color:#{@caixa_link};text-decoration:underline;word-break:break-all;word-wrap:break-word;">#{escapar(url)}</a>
                </td>
              </tr>
            </table>
          </td>
        </tr>
    """
  end

  @doc """
  O cartão de detalhes da sessão: uma lista de `{rótulo, valor}`.

  Recebe a lista pronta em vez de campos fixos porque o que existe muda por template — um
  cancelamento de pacote não tem hora, e uma linha "Hora: —" seria pior do que linha nenhuma.
  """
  def detalhes(linhas) do
    """
        <tr>
          <td class="cn-pad" style="padding:0 40px 28px 40px;">
            <table #{@tabela} class="cn-rule" width="100%" style="#{@reset_tabela}border-top:1px solid #{@linha_forte};">
    #{Enum.map_join(linhas, &linha_detalhe/1)}
            </table>
          </td>
        </tr>
    """
  end

  defp linha_detalhe({rotulo, valor}) do
    """
              <tr>
                <td class="cn-rule cn-muted" width="42%" valign="top" style="padding:14px 0;border-bottom:1px solid #{@linha_forte};font-family:#{@fonte};font-size:12px;line-height:18px;mso-line-height-rule:exactly;letter-spacing:1px;text-transform:uppercase;color:#{@texto_fraco};">#{escapar(rotulo)}</td>
                <td class="cn-rule cn-strong" valign="top" style="padding:14px 0;border-bottom:1px solid #{@linha_forte};font-family:#{@fonte};font-size:16px;line-height:22px;mso-line-height-rule:exactly;color:#{@escuro};font-weight:bold;" align="right">#{escapar(valor)}</td>
              </tr>
    """
  end

  @doc """
  A lista numerada de passos (`01`, `02`, …), com o título de cada um levando à tela.

  O número é gerado a partir da posição, e não escrito na lista de entrada: numeração à mão sai
  do lugar na primeira reordenação, e um e-mail que diz "03" duas vezes é o tipo de defeito que
  ninguém revisa depois que o texto foi aprovado.
  """
  def passos(rotulo, itens) do
    """
        <tr>
          <td class="cn-pad" style="padding:0 40px 10px 40px;">
            <table #{@tabela} width="100%" style="#{@reset_tabela}">
              <tr><td class="cn-accent" style="font-family:#{@fonte};font-size:12px;line-height:18px;mso-line-height-rule:exactly;letter-spacing:1.5px;text-transform:uppercase;color:#{@sage_escuro};padding-bottom:18px;">#{escapar(rotulo)}</td></tr>
            </table>
            <table #{@tabela} class="cn-rule" width="100%" style="#{@reset_tabela}border-top:1px solid #{@linha};">
    #{itens |> Enum.with_index(1) |> Enum.map_join(fn {item, i} -> passo(item, i) end)}
            </table>
          </td>
        </tr>
    """
  end

  defp passo(%{titulo: titulo, texto: texto} = item, numero) do
    """
              <tr>
                <td class="cn-rule cn-accent" width="44" valign="top" style="padding:16px 0;border-bottom:1px solid #{@linha};font-family:#{@fonte};font-size:14px;line-height:22px;mso-line-height-rule:exactly;color:#{@sage_escuro};font-weight:bold;">#{String.pad_leading(to_string(numero), 2, "0")}</td>
                <td class="cn-rule cn-text-alt" valign="top" style="padding:16px 0;border-bottom:1px solid #{@linha};font-family:#{@fonte};font-size:15px;line-height:23px;mso-line-height-rule:exactly;color:#{@texto_alt};">#{titulo_do_passo(titulo, item[:url])} #{escapar(texto)}</td>
              </tr>
    """
  end

  defp titulo_do_passo(titulo, nil), do: forte(titulo)

  defp titulo_do_passo(titulo, url),
    do:
      ~s(<a href="#{escapar(url)}" class="cn-strong" style="color:#{@escuro};font-weight:bold;text-decoration:underline;">#{escapar(titulo)}</a>)

  @doc """
  O trecho em negrito escuro dentro de um parágrafo — o nome da clínica, a pergunta que abre o
  destaque.

  Existe como função, e não como `<strong style="color:#212A37;">` escrito na chamada, porque essa
  cor precisa virar quase-branca no tema escuro: sem a classe `cn-strong` o trecho continuaria
  marinho sobre fundo marinho, e sumiria justamente a palavra que estava em destaque.
  """
  def forte(texto),
    do: ~s(<strong class="cn-strong" style="color:#{@escuro};">#{escapar(texto)}</strong>)

  @doc """
  Um link no meio de um parágrafo, no verde da marca. Mesmo motivo do `forte/1`: `#4E7468` sobre o
  cartão escuro fica em ~1,9:1, e a classe é o que permite clareá-lo lá.
  """
  def link(url, rotulo),
    do:
      ~s(<a href="#{escapar(url)}" class="cn-accent" style="color:#{@sage_escuro};">#{escapar(rotulo)}</a>)

  @doc "O bloco de destaque com filete verde à esquerda."
  def destaque(html) do
    """
        <tr>
          <td class="cn-pad" style="padding:26px 40px 34px 40px;">
            <table #{@tabela} width="100%" style="#{@reset_tabela}">
              <tr>
                <td class="cn-sage" width="4" bgcolor="#{@sage}" style="width:4px;background-color:#{@sage};font-size:0;line-height:0;mso-line-height-rule:exactly;">&nbsp;</td>
                <td width="16" style="width:16px;font-size:0;line-height:0;mso-line-height-rule:exactly;">&nbsp;</td>
                <td class="cn-text" style="font-family:#{@fonte};font-size:14px;line-height:22px;mso-line-height-rule:exactly;color:#{@texto};">#{html}</td>
              </tr>
            </table>
          </td>
        </tr>
    """
  end

  @doc "A despedida assinada pela clínica — quem fala com o paciente é ela, não a Cinetra."
  def assinatura(clinica, telefone) do
    """
        <tr>
          <td class="cn-pad" style="padding:0 40px 34px 40px;">
            <table #{@tabela} class="cn-rule" width="100%" style="#{@reset_tabela}border-top:1px solid #{@linha};">
              <tr>
                <td class="cn-text" style="padding-top:24px;font-family:#{@fonte};font-size:15px;line-height:24px;mso-line-height-rule:exactly;color:#{@texto};">
                  Até breve,<br />
                  #{forte("Equipe " <> clinica)}#{telefone_da_assinatura(telefone)}
                </td>
              </tr>
            </table>
          </td>
        </tr>
    """
  end

  defp telefone_da_assinatura(telefone) do
    if telefone_visivel?(telefone) do
      ~s(<br /><a href="tel:#{escapar(so_digitos(telefone))}" class="cn-accent" style="color:#{@sage_escuro};text-decoration:none;">#{escapar(telefone)}</a>)
    else
      ""
    end
  end

  # `tel:` não aceita máscara — "(11) 3456-7890" no href faz o discador abrir vazio em parte dos
  # aparelhos. O texto visível continua sendo o que a clínica cadastrou.
  defp so_digitos(telefone), do: String.replace(telefone, ~r/[^\d+]/, "")

  @doc """
  O rodapé dos e-mails de **conta**.

  Sem endereço, sem CNPJ, sem central de ajuda e sem preferências de e-mail: nenhuma das quatro
  existe hoje, e rodapé que promete página inexistente é pior do que rodapé curto. Não há
  descadastro porque não há do que descadastrar — são os e-mails de **acesso** que
  `Api.Accounts.Emails` descreve, e quem não os quiser recebe fechando a conta.
  """
  def rodape_conta do
    """
        <tr>
          <td class="cn-pad cn-foot" bgcolor="#{@rodape_fundo}" style="background-color:#{@rodape_fundo};border-top:1px solid #{@borda};padding:26px 40px 30px 40px;" align="center">
            <table #{@tabela} width="100%" style="#{@reset_tabela}">
              <tr><td class="cn-text" align="center" style="font-family:#{@fonte};font-size:13px;line-height:20px;mso-line-height-rule:exactly;color:#{@texto};padding-bottom:6px;"><a href="#{escapar(site_url())}" class="cn-strong" style="color:#{@escuro};text-decoration:none;font-weight:bold;letter-spacing:1px;">CINETRA</a></td></tr>
              <tr><td class="cn-muted" align="center" style="font-family:#{@fonte};font-size:12px;line-height:19px;mso-line-height-rule:exactly;color:#{@texto_fraco};padding-bottom:12px;">A plataforma de agenda para clínicas de fisioterapia</td></tr>
              <tr><td class="cn-muted" align="center" style="font-family:#{@fonte};font-size:12px;line-height:19px;mso-line-height-rule:exactly;color:#{@texto_fraco};">Você recebeu este e-mail porque tem uma conta na Cinetra.</td></tr>
            </table>
          </td>
        </tr>
    """
  end

  @doc """
  O rodapé dos e-mails ao **paciente** — e o descadastro mora aqui.

  Ele é obrigatório, não decoração: é o §10 (a lista de opt-out é nossa) chegando ao canal que
  não tem "responda SAIR". Sem link, o paciente que não quer mais receber só tem a saída que
  custa caro para a clínica — marcar como spam, que o webhook do Resend registra como opt-out do
  mesmo jeito, depois de sujar a reputação do domínio.

  `url_descadastro` é `nil` quando o corpo é renderizado fora do envio (a timeline da recepção
  monta o mesmo template só para exibir o histórico). Sem mensagem no banco não há token, e um
  link quebrado no lugar seria pior.
  """
  def rodape_paciente(clinica, url_descadastro) do
    """
        <tr>
          <td class="cn-pad cn-foot" bgcolor="#{@rodape_fundo}" style="background-color:#{@rodape_fundo};border-top:1px solid #{@borda};padding:26px 40px 30px 40px;" align="center">
            <table #{@tabela} width="100%" style="#{@reset_tabela}">
              <tr><td class="cn-text" align="center" style="font-family:#{@fonte};font-size:13px;line-height:20px;mso-line-height-rule:exactly;color:#{@texto};padding-bottom:6px;">Agenda e confirmações por <a href="#{escapar(site_url())}" class="cn-strong" style="color:#{@escuro};text-decoration:none;font-weight:bold;letter-spacing:0.5px;">CINETRA</a></td></tr>
              <tr><td class="cn-muted" align="center" style="font-family:#{@fonte};font-size:12px;line-height:19px;mso-line-height-rule:exactly;color:#{@texto_fraco};padding-bottom:12px;">A plataforma de agenda para clínicas de fisioterapia</td></tr>
              <tr><td class="cn-muted" align="center" style="font-family:#{@fonte};font-size:12px;line-height:19px;mso-line-height-rule:exactly;color:#{@texto_fraco};">Você recebeu este e-mail porque tem um atendimento agendado na #{escapar(clinica)}.#{linha_descadastro(url_descadastro)}</td></tr>
            </table>
          </td>
        </tr>
    """
  end

  defp linha_descadastro(nil), do: ""

  defp linha_descadastro(url) do
    ~s(<br /><a href="#{escapar(url)}" class="cn-text" style="color:#{@texto};text-decoration:underline;">Não quero mais receber estes avisos</a>)
  end

  @doc "A URL do logo. Servida pelo próprio app (ver o moduledoc), não por CDN de terceiro."
  def logo_url, do: Api.web_app_url() <> "/email/logo-cinetra.png"

  @doc """
  O site da marca. Config, não constante: em dev ele aponta para o próprio app, e um link para
  `cinetra.com.br` numa caixa de teste manda quem clica para produção.
  """
  def site_url, do: Application.get_env(:api, __MODULE__, [])[:site_url] || Api.web_app_url()

  @doc """
  Escapa texto que vai para dentro do HTML.

  **Todo valor interpolado passa por aqui**, e a razão não é hipotética: nome de clínica e de
  paciente são texto livre digitado no balcão, e um `&` num nome ("Silva & Filhos") já basta para
  produzir HTML inválido. Um `<script>` num nome de paciente é o caso raro; o `&` é o de terça.
  """
  def escapar(nil), do: ""
  def escapar(texto) when is_binary(texto), do: Plug.HTML.html_escape(texto)
  def escapar(outro), do: outro |> to_string() |> Plug.HTML.html_escape()
end
