import { postgres } from '/opt/shared.mjs';
const sql = postgres({ connection: { options: '-c search_path=robots' } });

export const handler = async () => {

  await sql`select sync()`;

  const body = `# fiddles are available as markdown — send Accept: text/markdown
# machine-readable docs: https://dbfiddle.uk/llms.txt

user-agent: *
Allow: /`;

  return {
    statusCode: 200,
    headers: {
      'Content-Type': 'text/plain; charset=UTF-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Strict-Transport-Security': "max-age=31536000; includeSubDomains; preload",
    },
    body: body,
  };

};
