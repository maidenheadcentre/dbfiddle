import { postgres } from '/opt/shared.mjs';

const sql = postgres({ connection: { options: '-c search_path=test' } });
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

export const handler = async event => {

  const [[data]] = await sql`select get()`.values();

  if(data!==null){

    const controller = new AbortController();
    const id = setTimeout(() => controller.abort(), 30000);
    const response = await fetch(`https://run.dbfiddle.uk/?type=${data.engine_code}_${data.version_code}${data.sample_name==='' ? '' : `&sample=${data.sample_name}`}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(JSON.stringify(data.engine_default)) },
      body: JSON.stringify(data.engine_default),
      signal: controller.signal,
    }).catch(e=>{});
    clearTimeout(id);

    const body = (response?.status===200) ? await response.text() : '';
    const valid = (response?.status===200) && body.substring(0,1)==='[';
    await (valid ? sql`select pass(${data.engine_code},${data.version_code},${data.sample_name})` : sql`select fail(${data.engine_code},${data.version_code},${data.sample_name})`);
    return body;

  }

};
