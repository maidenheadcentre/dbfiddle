drop schema if exists run cascade;
create schema run;
grant usage on schema run to lambda;
set search_path to run;
--
create function save(engine text, version text, sample text, input text[], output jsonb[]) returns bytea as $$
declare
  code bytea = gen_random_bytea(6);
  actual bytea;
begin
  loop
    begin
      --
      with i as (insert into fiddle(engine_code,version_code,sample_name,fiddle_hash,fiddle_code,fiddle_input,fiddle_output_json,fiddle_output)
                 values(engine
                      , version
                      , sample
                      , decode(md5(convert_to(to_json(input)::text,'utf8')),'hex')
                      , code
                      , input
                      , output
                      , case when jsonb_typeof(output[1])='string' then (select array_agg(j::text) from (select unnest(output) j) z) end)
                 on conflict(engine_code,version_code,sample_name,fiddle_hash) do update set fiddle_output_json = excluded.fiddle_output_json
                                                                                           , fiddle_output = excluded.fiddle_output
                 returning engine_code,version_code,sample_name,fiddle_at,fiddle_code)
        , i2 as (insert into fiddle_daily(engine_code,version_code,sample_name)
                 select engine_code,version_code,sample_name from i
                 on conflict (engine_code,version_code,sample_name,fiddle_daily_on) do update set fiddle_daily_count = fiddle_daily.fiddle_daily_count+1)
      select fiddle_code from i into actual;
      --
      return actual;
    exception when unique_violation then
      code = gen_random_bytea(6);
    end;
  end loop;
end;
$$ language plpgsql security definer set search_path=public,run,pg_temp;
