import postgres from 'postgres';

const sql = postgres({ connection: { options: '-c search_path=run' } });
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

export const handler = async (event) => {
  try {
    const qp = event.queryStringParameters;
    const url = `https://run.dbfiddle.uk/?type=${qp.engine}_${qp.version+(Object.hasOwn(qp,'sample') ? `&sample=${qp.sample}` : '')}`;
    const headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(event.body) };
    const result = await (await fetch(url, { method: "POST", body: event.body, headers })).json();
    const [[data]] = await sql`select save(${qp.engine},${qp.version},${qp?.sample ?? ''},array(select jsonb_array_elements_text(${event.body}::text::jsonb)),array(select jsonb_array_elements(${result})))`.values();
    return { statusCode: 200, headers: { 'Content-Type': 'text/plain; charset=UTF-8' }, body: data.toString('base64url') };
  } catch(e) {
    if( (e.name==='PostgresError') && (e.code.slice(0,2)==='H0') ) return { statusCode: +e.code.slice(2), body: `{ "message": "${e.detail}" }` };
    return { statusCode: 500, body: `{ message": "run failed" }` };
  }
};
