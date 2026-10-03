import { postgres, compressed, asset } from '/opt/shared.mjs';
const sql = postgres({ connection: { options: '-c search_path=home' } });

export const handler = async (event) => {

  const qp = event.queryStringParameters;

  // legacy url support eg "/?rdbms=postgres_13&fiddle=21f573acfaccb7bed87d20891e10968d"
  if( qp && Object.hasOwn(qp,'rdbms') ) {

    const [[code]] = await (
      Object.hasOwn(qp,'fiddle')
        ? sql`select redirect(${qp.rdbms.split('_',2)[0]},${qp.rdbms.split('_',2)[1]},${qp?.sample || ''},${Buffer.from(qp.fiddle, 'hex')})`
        : sql`select redirect(${qp.rdbms.split('_',2)[0]},${qp.rdbms.split('_',2)[1]},${qp?.sample || ''})`
    ).values();
    
    if(!code) return { statusCode: 404, body: JSON.stringify('not found') };
    return { statusCode: 301, headers: { 'Location': `/${code.toString('base64url')}${qp?.hide ? '?hide='+qp.hide : ''}` } };
    
  }

  const [[data]] = await sql`select get()`.values();

  // redirect engine name link (eg "/?engine=postgres") to default fiddle
  if( qp && Object.hasOwn(qp,'engine') ) {
    const engine = data.engines.find(e => e.code===qp.engine);
    if(engine?.fiddle) return { statusCode: 302, headers: { 'Location': `/${Buffer.from(engine.fiddle, 'hex').toString('base64url')}${engine.query ? '?'+engine.query : ''}` } };
    return { statusCode: 404, body: JSON.stringify('not found') };
  }

  const total = data.engines.reduce((p,c) => p + c.total, 0);

  const body = /*html*/`<!DOCTYPE html>
<html>
<head>
  <title>db<>fiddle</title>
  <meta name="description" content="a free online environment to experiment with SQL">
  <meta property="og:title" content="db<>fiddle">
  <meta property="og:description" content="a free online environment to experiment with SQL">
  <meta property="og:url" content="https://${event.requestContext.domainName}/">
  <meta property="og:image" content="https://${event.requestContext.domainName}${asset('logo.png')}">
  <meta name="theme-color" content="#2a5fcd">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="describedby" href="/llms.txt" type="text/plain" title="API notes for language models">
  <link rel="icon" href="${asset('favicon.ico')}">
  <link href="${asset('reset.css')}" rel="stylesheet">
  <link href="${asset('global.css')}" rel="stylesheet">
  <link href="${asset('home.css')}" rel="stylesheet">
  <script src="${asset('echarts.js')}" defer></script>
  <script src="${asset('home.js')}" defer></script>
</head>
<body>
  <header>
    <div>
      <a href="/">db<>fiddle</a>
    </div>
    <div>
      <a href='https://github.com/sponsors/jackdouglas'>donate</a>
      <span>·</span>
      <a href='https://github.com/maidenheadcentre/dbfiddle/issues'>feedback</a>
      <span>·</span>
      <a href='https://github.com/maidenheadcentre/dbfiddle#readme'>about</a>
      <span>·</span>
      <a href='/llms.txt'>llms.txt</a>
    </div>
  </header>
  <main>
    <p>${total.toLocaleString()} fiddles from about ${(100 * Math.round(data.source_total_count*1.5/100)).toLocaleString()} IP addresses</p>
    <a id="chart" href="/HVW0ex-y?render=echarts" aria-label="fiddles per day by engine" data-chart="${JSON.stringify(data.chart).replaceAll('"','&quot;')}"></a>
    <ul>${data.engines.reduce((p,engine) => /*html*/`${p}
      <li>
        ${engine.fiddle ? /*html*/`<a href="/${Buffer.from(engine.fiddle,'hex').toString('base64url')}${engine.query ? '?'+engine.query : ''}">${engine.name}</a>` : /*html*/`<span>${engine.name}</span>`}
        <div>${engine.versions.reduce((p,version) => /*html*/`${p}
          <${version.fiddle ? `a href="/${Buffer.from(version.fiddle,'hex').toString('base64url')}${version.query ? '?'+version.query : ''}"` : 'span'}${version.is_default ? ' class="default"' : ''}${version.is_down ? ' data-down' : ''}>
            ${version.name}
          </${version.fiddle ? 'a' : 'span'}>`, '')}
        </div>
      </li>`, '')}
    </ul>
    <details>
      <summary>privacy</summary>
      <ul>
        <li>we only <b>log the first 3 octets of your IP</b> (so the total number of IPs above is an estimate)</li>
        <li>we <b>do not track users in any other way</b>: no cookies, tracking scripts, fingerprinting, etc, etc</li>
        <li>adverts are hosted so the <b>advertiser only knows you exist if you click</b></li>
        <li>although covered by <a href="https://creativecommons.org/publicdomain/zero/1.0/legalcode">Creative Commons CC0</a>, <b>fiddles are not enumerable</b>, so if you don't publish a link they aren't visible to anyone else</li>
      </ul>
    </details>
  </main>
  <footer>
  <div>db<>fiddle © 2017-${new Date().getFullYear()} Jack Douglas</div>
  <div><a href="https://github.com/maidenheadcentre/dbfiddle"><img src="${asset('github.svg')}" alt="GitHub"></a><a href="https://x.com/dbfiddleuk"><img src="${asset('x.svg')}" alt="X"></a></div>
  </footer>
</body>
</html>`

  const headers = {
    'Content-Type': 'text/html; charset=UTF-8',
    'Link': '</llms.txt>; rel="describedby"',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "base-uri 'none'; frame-ancestors 'none'; default-src 'self'; style-src-attr 'unsafe-inline'; form-action 'self'",
    'Strict-Transport-Security': "max-age=31536000; includeSubDomains; preload",
  };

  return { statusCode: 200, ...compressed(body, headers, event.headers?.['accept-encoding']) };

};
