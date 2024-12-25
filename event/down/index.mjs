import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";
import * as Sentry from "@sentry/aws-serverless";
import postgres from 'postgres';

const sql = postgres({ connection: { options: '-c search_path=down' } });
Sentry.init({ dsn: process.env.SENTRY, tracesSampleRate: 0.01 });
const ses = new SESClient({ region: "eu-west-2" });
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

export const handler = Sentry.wrapHandler(async (event,context) => {

  Sentry.setContext("event", event);
  Sentry.setContext("http", event.requestContext);
  const [[data]] = await sql`select get()`.values();

  if(data!==null){

    data.functionName = context?.functionName;
    Sentry.setContext("data", data);

    const controller = new AbortController();
    const id = setTimeout(() => controller.abort(), 30000);
    const response = await fetch(`https://run.dbfiddle.uk/?type=${data.engine_code}_${data.version_code}${data.sample_name==='' ? '' : `&sample=${data.sample_name}`}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(JSON.stringify(data.engine_default)) },
      body: JSON.stringify(data.engine_default),
      signal: controller.signal
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
          Source: 'noreply@dbfiddle.uk'
        }));
      }
    } else {
      if(valid){
        return ses.send(new SendEmailCommand({
          Destination: { ToAddresses: [process.env.ADMINEMAIL] },
          Message: { Body: { Text: { Charset: "UTF-8", Data: JSON.stringify(data,null,2) } }, Subject: { Charset: 'UTF-8', Data: `${data.engine_code} ${data.version_code} is up after ${interval}` } },
          Source: 'noreply@dbfiddle.uk'
        }));
      }
    }
  }
});
