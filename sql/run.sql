drop schema if exists run cascade;
create schema run;
grant usage on schema run to lambda;
set search_path to run;
--
create function save(engine text, version text, sample text, input text[], output jsonb[], ip inet default null, agent text default null, lang text[] default null) returns bytea as $$
declare
  code bytea = gen_random_bytea(6);
  actual bytea;
begin
  insert into source(source_network) select set_masklen(ip::cidr,24) where ip is not null on conflict do nothing;
  loop
    begin
      --
      with i as (insert into fiddle(engine_code,version_code,sample_name,fiddle_code,source_network,fiddle_agent)
                 values(engine
                      , version
                      , sample
                      , code
                      , set_masklen(ip::cidr,24)
                      , agent)
                 returning engine_code,version_code,sample_name,fiddle_at,fiddle_code)
        , i2 as (insert into fiddle_daily(engine_code,version_code,sample_name)
                 select engine_code,version_code,sample_name from i
                 on conflict (engine_code,version_code,sample_name,fiddle_daily_on) do update set fiddle_daily_count = fiddle_daily.fiddle_daily_count+1)
      select fiddle_code from i into actual;
      --
      insert into batch(engine_code,version_code,sample_name,fiddle_code,language_code,batch_ordinal,batch_input,batch_output)
      select engine, version, sample, code, coalesce(nullif(lang[i],''),'sql'), i, input[i], output[i] #>> '{}'
      from generate_subscripts(input,1) i;
      --
      return actual;
    exception when unique_violation then
      code = gen_random_bytea(6);
    end;
  end loop;
end;
$$ language plpgsql security definer set search_path=public,run,pg_temp;
