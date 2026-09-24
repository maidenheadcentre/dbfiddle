import { postgres, accepts, compressed } from '/opt/shared.mjs';
const sql = postgres({ connection: { options: '-c search_path=dump' } });

export const handler = async (event) => {

  if(!accepts(event.headers?.['accept-encoding']).some(e => e === 'br' || e === 'gzip')) return { statusCode: 406 };

  const [[body]] = await sql`select daily()`.values();

  const headers = {
    'Content-Type': 'text/csv; charset=UTF-8',
    'Cache-Control': 'public, max-age=3600',
    'X-Content-Type-Options': 'nosniff',
    'Strict-Transport-Security': "max-age=31536000; includeSubDomains; preload",
  };

  return { statusCode: 200, ...compressed(body, headers, event.headers?.['accept-encoding']) };

};
