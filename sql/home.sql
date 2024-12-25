drop schema if exists home cascade;
create schema home;
grant usage on schema home to lambda;
set search_path = home;
--
create function get() returns jsonb as $$
  select to_jsonb(z)
  from
    ( select
        coalesce(reltuples::integer,0) source_total_count
      , ( select json_agg(z order by engine_total_90 desc)
          from
            ( select
                engine_code
              , engine_name
              , engine_total
              , engine_total_90
              , engine_total_7
              , ( select encode(fiddle_code,'hex')
                  from fiddle f
                  where
                    f.engine_code=e.engine_code and
                    f.version_code=e.engine_default_version_code and 
                    f.sample_name='' and
                    f.fiddle_hash=decode(md5(convert_to(to_jsonb(e.engine_default)::text,'utf8')),'hex')
                ) engine_fiddle_code
              , ( select json_agg(z order by total90 desc)
                  from
                    ( select
                        version_code code
                      , version_name "name"
                      , version_total total
                      , version_total_90 total90
                      , version_total_7 total7
                      , ( select encode(fiddle_code,'hex')
                          from fiddle f
                          where
                            v.version_is_active and
                            f.engine_code=v.engine_code and
                            f.version_code=v.version_code and 
                            f.sample_name='' and
                            f.fiddle_hash=decode(md5(convert_to(to_jsonb(e.engine_default)::text,'utf8')),'hex')
                        ) fiddle_code
                      from
                        version v
                        natural join
                          ( select
                              engine_code
                            , version_code
                            , coalesce(sum(fiddle_daily_count),0)::integer version_total
                            , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on<current_date and fiddle_daily_on>=current_date-90)),0)::integer version_total_90
                            , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on<current_date and fiddle_daily_on>=current_date-7)),0)::integer version_total_7
                            from fiddle_daily d
                            group by engine_code, version_code
                          ) z
                      where v.engine_code = e.engine_code
                    ) z
                ) versions
              from
                engine e
                natural join
                  ( select
                      engine_code
                    , coalesce(sum(fiddle_daily_count),0)::integer engine_total
                    , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on<current_date and fiddle_daily_on>=current_date-90)),0)::integer engine_total_90
                    , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on<current_date and fiddle_daily_on>=current_date-7)),0)::integer engine_total_7
                    from fiddle_daily
                    group by engine_code
                  ) z
            ) z
        ) engines
      , ( select json_agg(z order by name)
          from ( select engine_name || ' ' || version_name || case when sample_name<>'' then ' ('||sample_name||')' else '' end name, allowed_fail_since is not null is_down from engine natural join version natural join allowed ) z
        ) alloweds
      from pg_class
      where oid = 'public.source'::regclass 
    ) z;
$$ language sql security definer set search_path=home,public,pg_temp;
--
create function redirect(text,text,text,bytea) returns bytea as $$
  select fiddle_code from fiddle where engine_code=$1 and version_code=$2 and sample_name=$3 and fiddle_hash=$4;
$$ language sql security definer set search_path=home,public,pg_temp;
--
create function redirect(text,text,text) returns bytea as $$
  select fiddle_code from fiddle where engine_code=$1 and version_code=$2 and sample_name=$3 and fiddle_hash=(select decode(md5(convert_to(to_jsonb(engine_default)::text,'utf8')),'hex') from engine where engine_code=$1);
$$ language sql security definer set search_path=home,public,pg_temp;
