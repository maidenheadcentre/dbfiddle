import * as Sentry from "@sentry/aws-serverless";
import postgres from 'postgres';
import markdownit from 'markdown-it';
import markdownitbr from 'markdown-it-br';

const sql = postgres({ transform: { undefined: null }, connection: { options: '-c search_path=fiddle' } });
Sentry.init({ dsn: process.env.SENTRY, tracesSampleRate: 0.01 });

export const handler = Sentry.wrapHandler(async event => {

  Sentry.setContext("event", event);
  Sentry.setContext("http", event.requestContext);
  const md = markdownit().use(markdownitbr);

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
    return `${backtick} ${title}\n${markdown}\n${backtick}\n`;
  }

  function escapeMarkdownCell (m){
    return m.replace(/[[*/\|`_<&]/g, String.raw`\$&`).replace(/^ +/gm,m=>m.replaceAll(' ','&numsp;')).replace(/\r?\n|\r/g,'<br>');
  }

  const code = Buffer.from(event.pathParameters.code,'base64url');
  const [[data]] = await sql`select get(${code})`.values();
  if(!data) return { statusCode: 404, headers: { 'Content-Type': 'text/plain; charset=UTF-8' }, body: 'not found' };
  Sentry.setContext("data", data);
  await sql`select log(${event.requestContext.http.sourceIp},${event.headers?.referrer},${code})`;

  if((data.fiddle_output!==null) && (typeof(data.fiddle_output[0]) !== 'string')){
    data.fiddle_output.forEach( (item,index) => {

      let markdown = '';

      item.result.forEach( result => {

        if(Array.isArray(result?.data) && result.data.length) {
          const colCount = result.head.length;
          if(colCount) {
            markdown += '| ';
            for (let x = 0; x < colCount; x++) markdown += escapeMarkdownCell(result.head[x].toString()) + ' | ';
            markdown = markdown.slice(0,-1) + '\n| ';

            for (let x = 0; x < colCount; x++) {
              markdown += ( result.align[x] ? ':' : '-' ) + ("-".repeat(Math.max(0,result.head[x].length - 1))) + ( result.align[x] ? '-' : ':' ) + '|';
            }
            markdown += '\n';

            for (let y = 0; y < result.data[0].length; y++) {
              markdown += '| ';
              for (let x = 0; x < colCount; x++) {
                const val = result.data[x][y];
                markdown += ( (val === null) ? '*null*' : escapeMarkdownCell(val.toString()) ) + ' | ';
              }
              markdown = markdown.slice(0,-1) + '\n';
            }
            markdown += '\n';
          
          }
        }

        if( (result?.message ?? '') !== '') markdown += backtickWrapPre('status',result.message);

      });

      if( (item.error ?? '') !== '') markdown += backtickWrapPre('error',item.error);
      data.fiddle_output[index] = markdown;
    });
  }
 
  const hide = (+event.queryStringParameters?.hide ?? 0).toString(2).padStart(data.fiddle_input.length,'0').split('').map(b => b === "1");
  const highlight = (+event.queryStringParameters?.highlight ?? 0).toString(2).padStart(data.fiddle_input.length,'0').split('').map(b => b === "1");
  const batch = (input = '', output = '', index = null) => {
    return /*html*/`
      <div class="line${(index !== null && hide[index]) ? ' hide' : ''}${(index !== null && highlight[index]) ? ' highlight' : ''}">
        <div class="icon plus" title="add batch"><svg><use href="#plus"></use></svg></div>
        <div class="batch">
          <div class="controls">
            <div class="icon hamburger"><svg><use href="#hamburger"></use></svg></div>
            <div class="icon remove hidden" title="remove batch"><svg><use href="#remove"></use></svg></div>
            <div class="icon split hidden" title="split batch"><svg><use href="#split"></use></svg></div>
            <div class="icon hide hidden" title="hide batch"><svg><use href="#hide"></use></svg></div>
            <div class="icon highlight hidden" title="toggle highlight for batch"><svg><use href="#highlight"></use></svg></div>
          </div>
          <div class="io">
            <div class="input" data-markdown="${backtickWrapPre('',input.replaceAll('"','&quot;'))}"><textarea>${input.replaceAll('&','&amp;').replaceAll('<','&lt;')}</textarea></div>
            <div class="output" data-markdown="${output.replaceAll('"','&quot;')}">${(output !== '') ? md.render(output) : ''}</div>
          </div>
        </div>
        <div class="icon show" title="show hidden batches"><svg><use href="#show"></use></svg></div>
        <div class="icon plus" title="add batch"><svg><use href="#plus"></use></svg></div>
      </div>`;
  }

  const body = /*html*/`<!DOCTYPE html>
<html>
<head>
  <title>${data.engine_name} ${data.version_name} | db<>fiddle</title>
  <meta name="description" content="a free online environment to experiment with SQL and other code">
  <meta property="og:title" content="${data.engine_name} ${data.version_name}">
  <meta property="og:description" content="${data?.fiddle_output?.[0]?.replaceAll?.('"','&quot;')}">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" href="/static/favicon.71f8e287.ico">
  <link href="/static/reset.c4a60be7.css" rel="stylesheet">
  <link href="/static/global.2531dfe9.css" rel="stylesheet">
  <link href="/static/fiddle.39a276c9.css" rel="stylesheet">
  <link href="/static/qp.8db7ca63.css" rel="stylesheet">
  <script src="/static/codemirror.6fb49625.js" defer></script>
  <script src="/static/qp.ea500846.js" defer></script>
  <script src="/static/fiddle.10b8d2b1.js" defer></script>
  <template>${batch()}
  </template>
</head>
<body>
  <svg>
    <defs>
      <symbol id="plus" viewBox="0 0 10000 16" preserveAspectRatio="xMinYMid slice">
        <title>add batch</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="black" fill-opacity="0"/>
        <line x1="8" y1="3.5" x2="8" y2="12.5" stroke="black" stroke-width="1.5"/>
        <line x1="3.5" y1="8" x2="12.5" y2="8" stroke="black" stroke-width="1.5"/>
        <line x1="16" y1="8" x2="10000" y2="8" stroke="black"/>
      </symbol>
      <symbol id="hamburger" viewBox="0 0 16 16">
        <line x1="4" y1="4.5" x2="12" y2="4.5" stroke="black" stroke-width="1.5"/>
        <line x1="4" y1="8" x2="12" y2="8" stroke="black" stroke-width="1.5"/>
        <line x1="4" y1="11.5" x2="12" y2="11.5" stroke="black" stroke-width="1.5"/>
      </symbol>
      <symbol id="remove" viewBox="0 0 16 16">
        <title>remove batch</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="black" fill-opacity="0"/>
        <path d="M 12 4.5 L 11 12.5 L 5 12.5 L 4 4.5 Z" stroke="black" stroke-width="1.5" stroke-linejoin="round" fill-opacity="0"/>
        <line x1="7" y1="3.5" x2="9" y2="3.5" stroke="black" stroke-width="1.5"/>
        <line x1="6.5" y1="11.5" x2="6" y2="6.5" stroke="black" stroke-width="0.5"/>
        <line x1="8" y1="11.5" x2="8" y2="6.5" stroke="black" stroke-width="0.5"/>
        <line x1="9.5" y1="11.5" x2="10" y2="6.5" stroke="black" stroke-width="0.5"/>
      </symbol>
      <symbol id="split" viewBox="0 0 16 16">
        <title>split batch</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="black" fill-opacity="0"/>
        <line x1="3.5" y1="4.5" x2="12" y2="4.5" stroke="black" stroke-width="1.5"/>
        <line x1="7" y1="8" x2="12" y2="8" stroke="black" stroke-width="1.5"/>
        <line x1="7" y1="11.5" x2="12" y2="11.5" stroke="black" stroke-width="1.5"/>
        <line x1="7" y1="4.5" x2="7" y2="11.5" stroke="black" stroke-width="1.5"/>
      </symbol>
      <symbol id="comment" viewBox="0 0 16 16">
        <title>comment selection</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="black" fill-opacity="0"/>
      </symbol>
      <symbol id="show" viewBox="0 0 10000 16" preserveAspectRatio="xMinYMid slice">
        <title>show hidden batches</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="black" fill-opacity="0"/>
        <path d="M 3 8 A 5.5 5.5 0 0 1 13 8 M 13 8 A 5.5 5.5 0 0 1 3 8" stroke="black" stroke-width="1.5" fill-opacity="0"/>
        <circle cx="8" cy="8" r="1.5" stroke="black" fill-opacity="0"/>
        <line x1="16" y1="8" x2="10000" y2="8" stroke="black"/>
      </symbol>
      <symbol id="hide" viewBox="0 0 16 16">
        <title>hide batch</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="black" fill-opacity="0"/>
        <path d="M 3 8 A 5.5 5.5 0 0 1 13 8 M 13 8 A 5.5 5.5 0 0 1 3 8" stroke="black" stroke-width="1.5" fill-opacity="0"/>
        <circle cx="8" cy="8" r="1.5" stroke="black" fill-opacity="0"/>
        <line x1="13" y1="3" x2="3" y2="13" stroke-width="2" stroke="white"/>
        <line x1="12.5" y1="3.5" x2="3.5" y2="12.5" stroke="black"/>
      </symbol>
      <symbol id="highlight" viewBox="0 0 16 16">
        <title>highlight batch</title>
        <rect x="0.5" y="0.5" width="15" height="15" ry="3" rx="3" stroke="black" fill-opacity="0"/>
        <path d="M 8 4 L 5 7 L 10 12 L 13 9" stroke="black" stroke-width="1.5" fill-opacity="0" stroke-linejoin="round"/>
        <path d="M 6 8 L 3 11 3 12 L 8 12 9 11 Z" stroke="black" stroke-width="1.5" fill-opacity="1" stroke-linejoin="round"/>
      </symbol>
      <symbol id="spinner" viewBox="-1 -1 12 12">
        <circle cx="0" cy="5" r="1"/>
        <circle cx="1.464" cy="1.464" r="1"/>
        <circle cx="5" cy="0" r="1"/>
        <circle cx="8.536" cy="1.464" r="1"/>
        <circle cx="10" cy="5" r="1"/>
        <circle cx="8.536" cy="8.536" r="1"/>
        <circle cx="5" cy="10" r="1"/>
        <circle cx="1.464" cy="8.536" r="1"/>
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
        <option value="${v.version_code}"${v.version_code===e.engine_version_code?' selected':''}${v.version_is_active?'':' disabled'}>${v.version_name}</option>`, '')}
      </select>`, '')}${data.engines.reduce((p,e) => /*html*/`${p}${e.versions.reduce((p,v) => /*html*/`${p}
      <select class="sample${(e.engine_code!==data.engine_code)||(v.version_code!==data.version_code)?' hidden':''}${(v.samples.length<=1)?' empty':''}" data-engine="${e.engine_code}" data-version="${v.version_code}">${v.samples.reduce((p,c) => /*html*/`${p}
        <option value="${c.sample_name}"${c.sample_name===data.sample_name?' selected':''}>${c.sample_description}</option>`, '')}
      </select>`, '')}`, '')}
      <button id="run" accesskey="r"${data.version_is_active?'':' disabled'}><span>run</span><svg class="spinner"><use href="#spinner"></use></svg></button>
      <button id="abort" accesskey="r"><span>abort</span></button>
      <button id="markdown" accesskey="m">markdown</button>
    </div>
    <div>
      <a href='https://github.com/sponsors/jackdouglas'>donate</a>
      <a href='https://topanswers.xyz/fiddle?q=2035'>feedback</a>
      <a href='https://topanswers.xyz/fiddle?q=2036'>about</a>
    </div>
  </header>
  <main>
    <header>
      <div>By using db<>fiddle, you agree to license everything you submit by <a href="https://creativecommons.org/publicdomain/zero/1.0/legalcode">Creative Commons CC0</a>.</div>${(data.engine_code==='postgres')?/*html*/`
      <div>Help with an interesting Postgres question: <a href="https://topanswers.xyz/databases?q=2316">Why isn't an Index Only Scan used on a partition accessed via the parent table?</a>.</div>`:''}
    </header>
    <div>${data.fiddle_input.reduce((p,c,i) => /*html*/`${p}${batch(c,data?.fiddle_output?.[i],i)}`, '')}
    </div>
    <footer>${data.adverts.reduce((p,c) => /*html*/`${p}
      <a href="${c.url}"${c.words ? ' class="words"' : ''}>${c.image ? /*html*/`<img src="/static/${c.image}" alt="${c.alt}">` : ''}${c.words ? /*html*/`<div>${c.words}</div>` : ''}<div>${c.tagline}</div></a>`,'')}
    </footer>
  </main>
  <footer>
    <div><a href="/">db<>fiddle</a> © 2017-${new Date().getFullYear()} Jack Douglas</div>
    <div><a href="https://twitter.com/dbfiddleuk">twitter</a></div>
  </footer>
</body>
</html>`

return {
    statusCode: 200,
    headers: { 'Content-Type': 'text/html; charset=UTF-8'
             , 'Cache-Control': 'no-store'
             , 'X-Content-Type-Options': 'nosniff'
             , 'Content-Security-Policy': "base-uri 'none'; frame-ancestors 'none'; default-src 'self'; style-src 'self' 'unsafe-inline'"
             , 'Strict-Transport-Security': "max-age=31536000; includeSubDomains" },
    body: body,
  };
});