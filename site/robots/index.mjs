import postgres from 'postgres';
const sql = postgres({ connection: { options: '-c search_path=robots' } });

export const handler = async () => {

  await sql`select sync()`;

  const body = `user-agent: *
Allow: /$
Disallow: /`;

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'text/plain; charset=UTF-8'
             , 'Cache-Control': 'no-store'
             , 'X-Content-Type-Options': 'nosniff'
             , 'Strict-Transport-Security': "max-age=31536000; includeSubDomains" },
    body: body,
  };

};
