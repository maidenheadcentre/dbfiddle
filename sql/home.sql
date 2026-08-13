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
      , ( select json_agg(z order by total90 desc)
          from
            ( select
                engine_code code
              , engine_name "name"
              , engine_total total
              , engine_total_90 total90
              , engine_total_7 total7
              , engine_total_today total1
              , ( select encode(a.allowed_default_fiddle_code,'hex')
                  from allowed a
                  where
                    a.engine_code=e.engine_code and
                    a.version_code=e.engine_default_version_code and
                    a.sample_name=''
                ) fiddle
              , ( select json_agg(z order by total90 desc)
                  from
                    ( select
                        version_code code
                      , version_name "name"
                      , version_total total
                      , version_total_90 total90
                      , version_total_7 total7
                      , version_total_today total1
                      , ( select encode(a.allowed_default_fiddle_code,'hex')
                          from allowed a
                          where
                            v.version_is_active and
                            a.engine_code=v.engine_code and
                            a.version_code=v.version_code and
                            a.sample_name=''
                        ) fiddle
                      from
                        version v
                        natural join
                          ( select
                              engine_code
                            , version_code
                            , coalesce(sum(fiddle_daily_count),0)::integer version_total
                            , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on<current_date and fiddle_daily_on>=current_date-90)),0)::integer version_total_90
                            , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on<current_date and fiddle_daily_on>=current_date-7)),0)::integer version_total_7
                            , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on>=current_date)),0)::integer version_total_today
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
                    , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on>=current_date)),0)::integer engine_total_today
                    from fiddle_daily
                    group by engine_code
                  ) z
            ) z
        ) engines
      , ( select json_agg(z order by name)
          from ( select engine_name || ' ' || version_name || case when sample_name<>'' then ' ('||sample_name||')' else '' end name, allowed_fail_since is not null is_down from engine natural join version natural join allowed where version_is_active ) z
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
  select allowed_default_fiddle_code from allowed where engine_code=$1 and version_code=$2 and sample_name=$3;
$$ language sql security definer set search_path=home,public,pg_temp;
