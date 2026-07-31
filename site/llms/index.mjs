import { postgres, compressed } from '/opt/shared.mjs';
const sql = postgres({ connection: { options: '-c search_path=llms' } });

export const handler = async (event) => {

  const [[data]] = await sql`select get()`.values();
  const origin = `https://${event.requestContext.domainName}`;

  const body = `# db<>fiddle

Run SQL against a real database engine and get a permanent link to the result.
Free, no account needed. Everything submitted is [CC0](https://creativecommons.org/publicdomain/zero/1.0/legalcode).

## Reading a fiddle

Any fiddle URL returns markdown instead of HTML if you ask for it:

    GET ${origin}/{code}
    Accept: text/markdown

You get the SQL and its results batch by batch, ready to paste into an answer.
Batches hidden in the UI are included. Without the header you get the interactive page.

## Running SQL

    POST ${origin}/run?engine={engine}&version={version}
    Content-Type: application/json

    ["create table t (id int);", "insert into t values (1);", "select * from t;"]

Each array element is one batch. Batches run in order against the same fresh
database, so later ones see whatever earlier ones created.

Responds \`200\` with the new fiddle's code as plain text — the fiddle is then at
\`${origin}/{code}\`, which you can read as markdown using the header above.
Failures respond with \`{"message": "..."}\`.

The database starts empty. To start from a pre-loaded schema instead, add the
optional \`&sample={name}\`; the engine list below shows which versions offer one.

## Linking a fiddle for a person to read

    ?hide={n}       bitmask, most significant bit = first batch — collapses setup batches
    ?highlight={n}  same shape — highlights batches

## Engines and versions

Generated live; only versions that can currently be run are listed. Brackets show
the optional sample schemas a version offers, if any.

${data.map(e => `${e.code}: ${e.versions.map(v => v.code + (v.samples.length ? `[${v.samples.join(',')}]` : '')).join(' ')}`).join('\n')}

## Notes

Every run executes on a real disposable VM, so please don't poll or loop.
If you use a fiddle's output, linking it lets the reader re-run and change it.
`;

  const headers = {
    'Content-Type': 'text/plain; charset=UTF-8',
    'Cache-Control': 'public, max-age=3600',
    'X-Content-Type-Options': 'nosniff',
    'Strict-Transport-Security': "max-age=31536000; includeSubDomains; preload",
  };

  return { statusCode: 200, ...compressed(body, headers, event.headers?.['accept-encoding']) };

};
