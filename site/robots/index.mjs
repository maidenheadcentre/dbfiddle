
export const handler = async () => {

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
