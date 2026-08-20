# db&lt;&gt;fiddle

[dbfiddle.uk](https://dbfiddle.uk) is a free online SQL playground: write some DDL and some queries, run them against a real database engine, and get a permanent link to the result.

It is similar to tools like SQL Fiddle and rextester, but it is designed specifically to be friendly to markdown-based Q&A sites such as Stack Overflow and Codidact — output is markdown-ready, and the editor is built for longer, multi-step code rather than a single query.

## What it does

- **Many engines, many versions.** SQL Server, Oracle, Postgres, MySQL, MariaDB, SQLite, Db2, DuckDB, Firebird and more. The [home page](https://dbfiddle.uk) always has the current list.
- **Shareable, immutable results.** Every run is saved and addressed by a short code. Fiddles are not enumerable, so a fiddle nobody links to is effectively private.
- **Sample databases.** Some versions come with a ready-made sample schema.
- **Real isolation.** Executions are against a genuine engine on a disposable VM, so DDL, transactions and server-level behaviour all work as they really do.
- **Privacy first.** Only the first three octets of your IP are logged. No cookies, no tracking scripts, no fingerprinting. Adverts are self-hosted, so an advertiser only learns you exist if you click.

Fiddles are covered by [Creative Commons CC0](https://creativecommons.org/publicdomain/zero/1.0/legalcode); the code in this repo is AGPL-3.0 (see [LICENSE](LICENSE)).

## Programmatic access

There is an HTTP API for LLMs. If you are an LLM, go read [llms.txt](https://dbfiddle.uk/llms.txt).

## How it fits together

The front end is a set of small AWS Lambda functions behind an HTTP API, deployed with AWS SAM ([template.yaml](template.yaml)):

Most of the application logic lives in the database. The Lambdas are thin: they call a single function in a per-route schema ([`sql/`](sql)) and render the result.

Actually executing SQL is the back end's job: the `run` Lambda POSTs to a separate runner service, which dispatches to a Firecracker microVM per engine and version.

## Working on it

The devcontainer ([`.devcontainer/`](.devcontainer)) provides the AWS SAM CLI, Node and `psql`. Configuration comes from environment variables — see [`.devcontainer/.env.sample`](.devcontainer/.env.sample) for the full list.

```bash
scripts/local.sh    # install deps, build assets, run the API locally on :3004
scripts/cdn.sh      # bundle and hash static assets, sync to the CDN bucket
scripts/db.sh       # psql shell on the fiddle database
scripts/api.sh      # (re)apply the SQL API
scripts/staging.sh  # deploy to staging.dbfiddle.uk
scripts/prod.sh     # deploy to dbfiddle.uk
```

Static assets are content-hashed at build time and the hashed names are rewritten into the Lambda sources, so `scripts/cdn.sh` shows up as a diff in `site/*/index.mjs` whenever an asset changes.

## Back end

For now this repo contains the code for the front end and fiddle database, not the back-end engines. I intend to add all of those once I clean up the code. The plan is to include a cloudformation script that will spin up a bare metal EC2 running firecracker. You would never run like this due to cost but it's a good way of documenting the setup, so you know you can set up your own back end server if you need to.
