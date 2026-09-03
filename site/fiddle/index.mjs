import { postgres, compressed, accepts } from '/opt/shared.mjs';
import markdownit from 'markdown-it';
import markdownitbr from './br.mjs';

const sql = postgres({ transform: { undefined: null }, connection: { options: '-c search_path=fiddle' } });
const md = markdownit().use(markdownitbr);
const RENDERERS = { echarts: '/static/echarts.61f13280.js', mermaid: '/static/mermaid.581ed7d7.js' };

export const handler = async event => {

  function backtickCount (s = '') {
    let longestLength = 0;
    let currentLength = 0;
    for(let i = 0; i < s.length; i++){
      if(s[i] === '`'){
        currentLength++;
        if(currentLength > longestLength) longestLength++;
      } else {
        currentLength = 0;
      }
    }
    return longestLength;
  }  
  
  function backtickWrapPre (title = '', markdown = '') {
    const backtick = '`'.repeat(Math.max(3,backtickCount(markdown) + 1));
    return `${backtick}${title}\n${markdown}\n${backtick}\n`;
  }

  const code = Buffer.from(event.pathParameters.code,'base64url');
  const [[data]] = await sql`select get(${code})`.values();
  if(!data) return { statusCode: 404, headers: { 'Content-Type': 'text/plain; charset=UTF-8' }, body: 'not found' };
  if(event.requestContext.http.method !== 'HEAD') await sql`select log(${event.requestContext.http.sourceIp},${event.headers?.referer},${code},${event.headers?.['user-agent']},${event.headers?.accept})`;

  const showplan = (data.fiddle_output ?? []).some(o => (typeof o === 'string') && o.includes('Microsoft SQL Server 2005 XML Showplan'));
  const hide = (+event.queryStringParameters?.hide ?? 0).toString(2).padStart(data.fiddle_input.length,'0').split('').map(b => b === "1");
  const render = (event.queryStringParameters?.render ?? '').split(',').map(r => Object.hasOwn(RENDERERS, r) ? r : '');
  const batch = (input = '', output = '', index = null, lang = '') => {
    return /*html*/`
      <div class="line${(index !== null && hide[index]) ? ' hide' : ''}"${lang ? ` data-lang="${lang}"` : ''}${(index !== null && render[index]) ? ` data-render="${render[index]}"` : ''}>
        <div class="icon plus" title="add"><svg><use href="#plus"></use></svg></div>
        <div class="batch">
          <div class="controls">
            <div class="icon hamburger"><svg><use href="#hamburger"></use></svg></div>
            <div class="icon remove hidden" title="remove"><svg><use href="#remove"></use></svg></div>
            <div class="icon split hidden" title="split"><svg><use href="#split"></use></svg></div>
            <div class="icon hide hidden" title="hide"><svg><use href="#hide"></use></svg></div>
            <div class="icon language hidden" title="language"><svg><use href="#language"></use></svg></div>
            <div class="icon render hidden" title="render"><svg><use href="#chart"></use></svg></div>
          </div>
          <div class="io">
            <div class="input" data-markdown="${backtickWrapPre(lang || 'sql',input.replaceAll('&','&amp;').replaceAll('"','&quot;'))}"><textarea>${input.replaceAll('&','&amp;').replaceAll('<','&lt;')}</textarea></div>
            <div class="output" data-markdown="${output.replaceAll('&','&amp;').replaceAll('"','&quot;')}">${(output !== '') ? md.render(output) : ''}</div>
          </div>
        </div>
        <div class="icon show" title="show hidden"><svg><use href="#show"></use></svg></div>
        <div class="icon plus" title="add"><svg><use href="#plus"></use></svg></div>
      </div>`;
  }

  const origin = `https://${event.requestContext.domainName}`;

  if( accepts(event.headers?.accept).includes('text/markdown') ){
    const markdown = data.fiddle_input.reduce((p,c,i) => `${p}${backtickWrapPre(data?.fiddle_lang?.[i] || 'sql',c)}${data?.fiddle_output?.[i] ?? ''}`, '')
                   + `[fiddle](${origin}/${event.pathParameters.code})\n`;
    const headers = {
      'Content-Type': 'text/markdown; charset=UTF-8',
      'Link': '</llms.txt>; rel="describedby"',
      'Cache-Control': 'no-store',
      'Vary': 'Accept',
      'X-Robots-Tag': 'noindex',
      'X-Content-Type-Options': 'nosniff',
      'Strict-Transport-Security': "max-age=31536000; includeSubDomains; preload",
    };
    return { statusCode: 200, ...compressed(markdown, headers, event.headers?.['accept-encoding']) };
  }

  const ogDescription = (typeof data?.fiddle_output?.[0] === 'string' && data.fiddle_output[0] !== '')
    ? data.fiddle_output[0].slice(0, 400).trim().replaceAll('"','&quot;')
    : 'a free online environment to experiment with SQL and other code';

  const banner = !data.example ? '' : /*html*/`
      <div id="banner">${data.version_languages
          ? `${data.engine_name} runs ${new Intl.ListFormat('en-GB').format(data.version_languages)} alongside SQL`
          : `${data.example.name} runs ${data.example.language_name} alongside SQL`
        }: <a href="/${Buffer.from(data.example.code,'hex').toString('base64url')}">see an example</a>. ${
          data.version_languages ? 'request another language' : `request a language for ${data.engine_name}`
        } <a href="https://github.com/maidenheadcentre/dbfiddle/issues/new?template=language.yml&${new URLSearchParams({ title: `${data.engine_name}: <language>`, engine: data.engine_name })}">here</a>.</div>`;

  const body = /*html*/`<!DOCTYPE html>
<html>
<head>
  <title>${data.engine_name} ${data.version_name} | db<>fiddle</title>
  <meta name="description" content="a free online environment to experiment with SQL and other code">
  <meta property="og:site_name" content="db<>fiddle">
  <meta property="og:title" content="${data.engine_name} ${data.version_name}">
  <meta property="og:description" content="${ogDescription}">
  <meta property="og:url" content="${origin}/${event.pathParameters.code}">
  <meta property="og:image" content="${origin}/static/logo.3ccc0c3c.png">
  <meta name="theme-color" content="#2a5fcd">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="describedby" href="/llms.txt" type="text/plain" title="API notes for language models">
  <link rel="icon" href="/static/favicon.71f8e287.ico">
  <link href="/static/reset.c4a60be7.css" rel="stylesheet">
  <link href="/static/global.88b17cae.css" rel="stylesheet">
  <link href="/static/fiddle.92f8c38f.css" rel="stylesheet">${showplan ? /*html*/`
  <link href="/static/qp.8db7ca63.css" rel="stylesheet">` : ''}${Object.entries(RENDERERS).filter(([name]) => render.includes(name)).map(([, src]) => /*html*/`
  <link href="${src}" rel="preload" as="script">`).join('')}
  <script src="/static/codemirror.0adb24fc.js" defer></script>${showplan ? /*html*/`
  <script src="/static/qp.ea500846.js" defer></script>` : ''}
  <script src="/static/fiddle.aa39bb80.js" defer></script>
  <template>${batch()}
  </template>
</head>
<body>
  <svg>
    <defs>
      <symbol id="plus" viewBox="0 0 10000 16" preserveAspectRatio="xMinYMid slice">
        <title>add</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="currentColor" fill-opacity="0"/>
        <line x1="8" y1="3.5" x2="8" y2="12.5" stroke="currentColor" stroke-width="1.5"/>
        <line x1="3.5" y1="8" x2="12.5" y2="8" stroke="currentColor" stroke-width="1.5"/>
        <line x1="16" y1="8" x2="10000" y2="8" stroke="currentColor"/>
      </symbol>
      <symbol id="hamburger" viewBox="0 0 16 16">
        <line x1="4" y1="4.5" x2="12" y2="4.5" stroke="currentColor" stroke-width="1.5"/>
        <line x1="4" y1="8" x2="12" y2="8" stroke="currentColor" stroke-width="1.5"/>
        <line x1="4" y1="11.5" x2="12" y2="11.5" stroke="currentColor" stroke-width="1.5"/>
      </symbol>
      <symbol id="remove" viewBox="0 0 16 16">
        <title>remove</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="currentColor" fill-opacity="0"/>
        <path d="M 12 4.5 L 11 12.5 L 5 12.5 L 4 4.5 Z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" fill-opacity="0"/>
        <line x1="7" y1="3.5" x2="9" y2="3.5" stroke="currentColor" stroke-width="1.5"/>
        <line x1="6.5" y1="11.5" x2="6" y2="6.5" stroke="currentColor" stroke-width="0.5"/>
        <line x1="8" y1="11.5" x2="8" y2="6.5" stroke="currentColor" stroke-width="0.5"/>
        <line x1="9.5" y1="11.5" x2="10" y2="6.5" stroke="currentColor" stroke-width="0.5"/>
      </symbol>
      <symbol id="split" viewBox="0 0 16 16">
        <title>split</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="currentColor" fill-opacity="0"/>
        <line x1="3.5" y1="4.5" x2="12" y2="4.5" stroke="currentColor" stroke-width="1.5"/>
        <line x1="7" y1="8" x2="12" y2="8" stroke="currentColor" stroke-width="1.5"/>
        <line x1="7" y1="11.5" x2="12" y2="11.5" stroke="currentColor" stroke-width="1.5"/>
        <line x1="7" y1="4.5" x2="7" y2="11.5" stroke="currentColor" stroke-width="1.5"/>
      </symbol>
      <symbol id="language" viewBox="0 0 16 16">
        <title>language</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="currentColor" fill-opacity="0"/>
        <path d="M 5.2 5 L 3.2 8 L 5.2 11" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" fill-opacity="0"/>
        <line x1="9.1" y1="4.5" x2="6.9" y2="11.5" stroke="currentColor" stroke-width="1.5"/>
        <path d="M 10.8 5 L 12.8 8 L 10.8 11" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" fill-opacity="0"/>
      </symbol>
      <symbol id="chart" viewBox="0 0 16 16">
        <title>chart</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="currentColor" fill-opacity="0"/>
        <line x1="4.5" y1="12" x2="4.5" y2="8.5" stroke="currentColor" stroke-width="1.5"/>
        <line x1="8" y1="12" x2="8" y2="4" stroke="currentColor" stroke-width="1.5"/>
        <line x1="11.5" y1="12" x2="11.5" y2="6.5" stroke="currentColor" stroke-width="1.5"/>
      </symbol>
      <symbol id="show" viewBox="0 0 10000 16" preserveAspectRatio="xMinYMid slice">
        <title>show hidden</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="currentColor" fill-opacity="0"/>
        <path d="M 3 8 A 5.5 5.5 0 0 1 13 8 M 13 8 A 5.5 5.5 0 0 1 3 8" stroke="currentColor" stroke-width="1.5" fill-opacity="0"/>
        <circle cx="8" cy="8" r="1.5" stroke="currentColor" fill-opacity="0"/>
        <line x1="16" y1="8" x2="10000" y2="8" stroke="currentColor"/>
      </symbol>
      <symbol id="hide" viewBox="0 0 16 16">
        <title>hide</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="currentColor" fill-opacity="0"/>
        <path d="M 3 8 A 5.5 5.5 0 0 1 13 8 M 13 8 A 5.5 5.5 0 0 1 3 8" stroke="currentColor" stroke-width="1.5" fill-opacity="0"/>
        <circle cx="8" cy="8" r="1.5" stroke="currentColor" fill-opacity="0"/>
        <line x1="13" y1="3" x2="3" y2="13" stroke-width="2" stroke="white"/>
        <line x1="12.5" y1="3.5" x2="3.5" y2="12.5" stroke="currentColor"/>
      </symbol>
      <symbol id="spinner" viewBox="-1 -1 12 12">
        <circle cx="0" cy="5" r="1" fill="currentColor"/>
        <circle cx="1.464" cy="1.464" r="1" fill="currentColor"/>
        <circle cx="5" cy="0" r="1" fill="currentColor"/>
        <circle cx="8.536" cy="1.464" r="1" fill="currentColor"/>
        <circle cx="10" cy="5" r="1" fill="currentColor"/>
        <circle cx="8.536" cy="8.536" r="1" fill="currentColor"/>
        <circle cx="5" cy="10" r="1" fill="currentColor"/>
        <circle cx="1.464" cy="8.536" r="1" fill="currentColor"/>
      </svg>
    </defs>
  </svg>
  <header>
    <div>
      <a href="/">db<>fiddle</a>
      <select id="engine">${data.engines.reduce((p,e) => /*html*/`${p}
        <option value="${e.engine_code}" data-separator="${e.engine_separator_regex}" ${e.engine_code===data.engine_code?' selected':''}>${e.engine_name}</option>`, '')}
      <select>${data.engines.reduce((p,e) => /*html*/`${p}
      <select class="version${e.engine_code!==data.engine_code?' hidden':''}" data-engine="${e.engine_code}">${e.versions.reduce((p,v) => /*html*/`${p}
        <option value="${v.version_code}" data-languages="${v.languages.join(',')}"${v.version_code===e.engine_version_code?' selected':''}${v.version_is_active?'':' disabled'}>${v.version_name}</option>`, '')}
      </select>`, '')}${data.engines.reduce((p,e) => /*html*/`${p}${e.versions.reduce((p,v) => /*html*/`${p}
      <select class="sample${(e.engine_code!==data.engine_code)||(v.version_code!==data.version_code)?' hidden':''}${(v.samples.length<=1)?' empty':''}" data-engine="${e.engine_code}" data-version="${v.version_code}">${v.samples.reduce((p,c) => /*html*/`${p}
        <option value="${c.sample_name}"${c.sample_name===data.sample_name?' selected':''}>${c.sample_description}</option>`, '')}
      </select>`, '')}`, '')}
      <button id="run" accesskey="r"${data.version_is_active||data.replacement?'':' disabled'}${data.replacement?` data-replacement="${data.replacement.code}"`:''}><span>run${data.replacement?` with ${data.replacement.name}`:''}</span><svg class="spinner"><use href="#spinner"></use></svg></button>
      <button id="abort" accesskey="r"><span>abort</span></button>
      <button id="markdown" accesskey="m">markdown</button>
      <button id="clear" accesskey="c">clear</button>
    </div>
    <div>
      <a href='https://github.com/sponsors/jackdouglas'>donate</a>
      <a href='https://github.com/maidenheadcentre/dbfiddle/issues'>feedback</a>
      <a href='https://github.com/maidenheadcentre/dbfiddle#readme'>about</a>
    </div>
  </header>
  <main${Object.entries(RENDERERS).map(([name, src]) => ` data-${name}="${src}"`).join('')}>
    <header>
      <div>By using db<>fiddle, you agree to license everything you submit by <a href="https://creativecommons.org/publicdomain/zero/1.0/legalcode">Creative Commons CC0</a>.</div>${banner}
    </header>
    <div>${data.fiddle_input.reduce((p,c,i) => /*html*/`${p}${batch(c,data?.fiddle_output?.[i],i,data?.fiddle_lang?.[i] ?? '')}`, '')}
    </div>${data.adverts.length?/*html*/`
    <footer>${data.adverts.reduce((p,c) => /*html*/`${p}
      <a href="${c.url}"${c.words ? ' class="words"' : ''}>${c.image ? /*html*/`<img src="/static/${c.image}" alt="${c.alt}">` : ''}${c.words ? /*html*/`<div>${c.words}</div>` : ''}<div>${c.tagline}</div></a>`,'')}
    </footer>` : '' }
  </main>
  <footer>
    <div><a href="/">db<>fiddle</a> © 2017-${new Date().getFullYear()} Jack Douglas</div>
    <div><a href="https://github.com/maidenheadcentre/dbfiddle"><img src="/static/github.138da068.svg" alt="GitHub"></a><a href="https://x.com/dbfiddleuk"><img src="/static/x.284fbff5.svg" alt="X"></a></div>
  </footer>
</body>
</html>`

  const headers = {
    'Content-Type': 'text/html; charset=UTF-8',
    'Link': '</llms.txt>; rel="describedby"',
    'Cache-Control': 'no-store',
    'Vary': 'Accept',
    'X-Robots-Tag': 'noindex',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "base-uri 'none'; frame-ancestors 'none'; default-src 'self'; style-src 'self' 'unsafe-inline'; form-action 'self'",
    'Strict-Transport-Security': "max-age=31536000; includeSubDomains; preload",
  };

  return { statusCode: 200, ...compressed(body, headers, event.headers?.['accept-encoding']) };

};
