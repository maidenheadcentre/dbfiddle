import postgres from 'postgres';
import zlib from 'node:zlib';

export { postgres };

// tokens from an Accept/Accept-Encoding header, dropping q=0 refusals
export const accepts = (header = '') => (header ?? '').split(',')
  .map(t => t.trim().split(';'))
  .filter(([,...params]) => !params.some(p => /^\s*q=0(\.0*)?\s*$/.test(p)))
  .map(([name]) => name.trim().toLowerCase());

// brotli q5 and gzip both cost ~0.1ms on a typical page; q11 is 200x slower for 1% more
export const compressed = (body, headers, accept = '') => {
  const offered = accepts(accept);
  const encoding = offered.includes('br') ? 'br' : offered.includes('gzip') ? 'gzip' : null;
  if(!encoding) return { headers, body };
  const buffer = (encoding === 'br')
    ? zlib.brotliCompressSync(body, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 5 } })
    : zlib.gzipSync(body);
  return {
    headers: { ...headers, 'Content-Encoding': encoding, 'Vary': headers.Vary ? `${headers.Vary}, Accept-Encoding` : 'Accept-Encoding' },
    body: buffer.toString('base64'),
    isBase64Encoded: true,
  };
};
