import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";
import { postgres } from '/opt/shared.mjs';

const sql = postgres({ connection: { options: '-c search_path=down' } });
const ses = new SESClient({ region: "eu-west-2" });
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

export const handler = async (event,context) => {

  const [[data]] = await sql`select get()`.values();

  if(data!==null){

    data.functionName = context?.functionName;

    const controller = new AbortController();
    const id = setTimeout(() => controller.abort(), 30000);
    const batches = JSON.stringify([data.engine_test]);
    const response = await fetch(`https://run.dbfiddle.uk/?type=${data.engine_code}_${data.version_code}${data.sample_name==='' ? '' : `&sample=${data.sample_name}`}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(batches) },
      body: batches,
      signal: controller.signal,
    }).catch(e=>{});
    clearTimeout(id);

    const body = (response?.status===200) ? await response.text() : '';
    const valid = (response?.status===200) && body.substring(0,1)==='[';
    const [[interval]] = await (valid ? sql`select pass(${data.engine_code},${data.version_code},${data.sample_name})` : sql`select fail(${data.engine_code},${data.version_code},${data.sample_name})`).values();

    if(data.is_new){
      if(!valid){
        return ses.send(new SendEmailCommand({
          Destination: { ToAddresses: [process.env.ADMINEMAIL] },
          Message: { Body: { Text: { Charset: "UTF-8", Data: JSON.stringify(data,null,2) } }, Subject: { Charset: 'UTF-8', Data: `${data.engine_code} ${data.version_code} is down with ${response?.status ?? 'timeout'}` } },
          Source: 'noreply@dbfiddle.uk',
        }));
      }
    } else {
      if(valid){
        return ses.send(new SendEmailCommand({
          Destination: { ToAddresses: [process.env.ADMINEMAIL] },
          Message: { Body: { Text: { Charset: "UTF-8", Data: JSON.stringify(data,null,2) } }, Subject: { Charset: 'UTF-8', Data: `${data.engine_code} ${data.version_code} is up after ${interval}` } },
          Source: 'noreply@dbfiddle.uk',
        }));
      }
    }
  }
};
