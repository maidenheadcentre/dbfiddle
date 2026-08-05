import { postgres } from '/opt/shared.mjs';

const sql = postgres({ connection: { options: '-c search_path=run' } });
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

const broken = 'The engine failed to run — this is not a problem with your fiddle. Please try again later.';
const messages = {
  400: 'That engine or version is not available.',
  413: 'Fiddle produced too much output.',
  500: broken,
  502: broken,
  503: 'The engine is busy right now. Please try again in a moment.',
  504: 'Fiddle took too long to run.',
};
// front end trusts this key: API Gateway 5xx has {message} too
const failed = status => ({
  statusCode: messages[status] ? status : 502,
  headers: { 'Content-Type': 'application/json; charset=UTF-8' },
  body: JSON.stringify({ message: messages[status] ?? broken, dbfiddle: true }),
});

export const handler = async (event) => {
  try {
    const qp = event.queryStringParameters;
    const url = `https://run.dbfiddle.uk/?type=${qp.engine}_${qp.version+(Object.hasOwn(qp,'sample') ? `&sample=${qp.sample}` : '')}`;
    const headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(event.body) };
    const response = await fetch(url, { method: "POST", body: event.body, headers });
    // must precede .json(): a parseable failure body would be saved as a fiddle
    if(!response.ok) return failed(response.status);
    const result = await response.json();
    const [[data]] = await sql`select save(${qp.engine},${qp.version},${qp?.sample ?? ''},array(select jsonb_array_elements_text(${event.body}::text::jsonb)),array(select jsonb_array_elements(${result})))`.values();
    return { statusCode: 200, headers: { 'Content-Type': 'text/plain; charset=UTF-8' }, body: data.toString('base64url') };
  } catch {
    return failed(500);
  }
};
