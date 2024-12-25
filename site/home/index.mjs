import postgres from 'postgres';
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
    const code = data.engines.find(e => e.engine_code===qp.engine)?.engine_fiddle_code;
    if(code) return { statusCode: 302, headers: { 'Location': `/${Buffer.from(code, 'hex').toString('base64url')}` } };
    return { statusCode: 404, body: JSON.stringify('not found') };
  }

  const totals = data.engines.reduce((p,c) => ({ total: p.total + c.engine_total, total_90: p.total_90 + c.engine_total_90, total_7: p.total_7 + c.engine_total_7 }), { total: 0, total_90: 0, total_7: 0 });

  const body = /*html*/`<!DOCTYPE html>
<html>
<head>
  <title>db<>fiddle</title>
  <meta name="description" content="a free online environment to experiment with SQL and Node.js">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" href="static/favicon.71f8e287.ico">
  <link href="static/reset.c4a60be7.css" rel="stylesheet">
  <link href="static/global.2531dfe9.css" rel="stylesheet">
  <link href="static/home.f5431712.css" rel="stylesheet">
  <script type="module" src="static/light.6d47cbec.js"></script>
</head>
<body>
  <header>
    <div>
      <a href="/">db<>fiddle</a>
    </div>
    <div>
      <a href='https://github.com/sponsors/jackdouglas'>donate</a>
      <a href='https://topanswers.xyz/fiddle?q=2035'>feedback</a>
      <a href='https://topanswers.xyz/fiddle?q=2036'>about</a>
    </div>
  </header>
  <main>
    <div>fiddles have been created from about ${(100 * Math.round(data.source_total_count*1.5/100)).toLocaleString()} distinct IP addresses</div>
    <table>
      <thead>
      <tr><th rowspan="2">engine</th><th colspan="3">fiddles created</th></tr>
      <tr><th>all time</th><th>90 day</th><th>7 day</th></tr>
      </thead>
      <tbody>
        <tr>
          <td>Total</td>
          <td>${totals.total.toLocaleString()}</td>
          <td>${totals.total_90.toLocaleString()}</td>
          <td>${totals.total_7.toLocaleString()}</td>
        </tr>
      </tbody>
      <tbody>${data.engines.reduce((p,c) => /*html*/`${p}
        <tr>
          <td><a href="/${Buffer.from(c.engine_fiddle_code,'hex').toString('base64url')}">${c.engine_name}</a></td>
          <td>${c.engine_total.toLocaleString()}</td>
          <td>${c.engine_total_90.toLocaleString()}</td>
          <td>${c.engine_total_7.toLocaleString()}</td>
        </tr>`, '')}
      </tbody>
    </table>
    <details>
      <summary>status <x-light></x-light>${data.alloweds.reduce((p,c) => c.is_down ? p : p = p+1, 0)} <x-light red></x-light>${data.alloweds.reduce((p,c) => c.is_down ? p = p+1 : p, 0)}</summary>
      <table>
        <thead>
          <tr>
            <th>version</th>
            <th>status</th>
          </tr>
        </thead>
        <tbody>${data.alloweds.reduce((p,c) => /*html*/`${p}
          <tr>
            <td>${c.name}</td>
            <td><x-light${c.is_down ? ' red' : ''}></x-light></td>
          </tr>`, '')}
        </tbody>
      </table>
    </details>
    <details>
      <summary>privacy</summary>
      <ul>
        <li>we only <b>log the first 3 octets of your IP</b> (so the total number of IPs above is an estimate)</li>
        <li>we <b>do not track users in any other way</b>: no cookies, tracking scripts, fingerprinting, etc, etc</li>
        <li><a href="https://topanswers.xyz/fiddle?q=2108">adverts</a> are hosted so the <b>advertiser only knows you exist if you click</b></li>
        <li>although covered by <a href="https://creativecommons.org/publicdomain/zero/1.0/legalcode">Creative Commons CC0</a>, <b>fiddles are not enumerable</b>, so if you don't publish a link they aren't visible to anyone else</li>
      </ul>
    </details>
  </main>
  <footer>
  <div>db<>fiddle © 2017-${new Date().getFullYear()} Jack Douglas</div>
  <div><a href="https://twitter.com/dbfiddleuk">twitter</a></div>
  </footer>
</body>
</html>`

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'text/html; charset=UTF-8'
             , 'Cache-Control': 'no-store'
             , 'X-Content-Type-Options': 'nosniff'
             , 'Content-Security-Policy': "base-uri 'none'; frame-ancestors 'none'; default-src 'self'; style-src-attr 'unsafe-inline'"
             , 'Strict-Transport-Security': "max-age=31536000; includeSubDomains" },
    body: body,
  };

};