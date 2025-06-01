
export const handler = async (event) => {

  const response = await fetch('https://mcc-fiddle-cdn.s3.eu-west-2.amazonaws.com/'+event.pathParameters.filename);
  const base64body = Buffer.from(await response.arrayBuffer()).toString('base64');

  return {
    statusCode: response.status,
    headers: { 'Content-Type': response.headers.get("Content-Type")
             , 'Cache-Control': 'public, max-age: 31536000, immutable'
             , 'Expires': new Date(Date.now()+31536000000).toUTCString()
             , 'X-Content-Type-Options': 'nosniff'
             , 'Content-Security-Policy': "base-uri 'none'; frame-ancestors 'none'; default-src none"
             , 'Strict-Transport-Security': 'max-age=31536000; includeSubDomains' },
    body: base64body,
    isBase64Encoded: true,
  };

};
