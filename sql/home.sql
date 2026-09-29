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
      , ( select json_agg(to_jsonb(z)-'total90' order by total90 desc)
          from
            ( select
                engine_code code
              , engine_name "name"
              , engine_total total
              , engine_total_90 total90
              , ( select encode(a.allowed_default_fiddle_code,'hex')
                  from allowed a
                  where
                    a.engine_code=e.engine_code and
                    a.version_code=e.engine_default_version_code and
                    a.sample_name=''
                ) fiddle
              , ( select json_agg(to_jsonb(z)-'ordinal' order by split_part(ordinal,'.',1)::int desc, nullif(split_part(ordinal,'.',2),'')::int desc, "name")
                  from
                    ( select
                        version_name "name"
                      , regexp_replace(version_code,'[^.0-9]','','g')::decimal::text ordinal
                      , version_code = e.engine_default_version_code is_default
                      , exists(select from allowed a where a.engine_code=v.engine_code and a.version_code=v.version_code and a.allowed_fail_since is not null) is_down
                      , ( select encode(a.allowed_default_fiddle_code,'hex')
                          from allowed a
                          where
                            a.engine_code=v.engine_code and
                            a.version_code=v.version_code and
                            a.sample_name=''
                        ) fiddle
                      from version v
                      where v.engine_code = e.engine_code and v.version_is_active
                    ) z
                ) versions
              from
                engine e
                natural join
                  ( select
                      engine_code
                    , coalesce(sum(fiddle_daily_count),0)::integer engine_total
                    , coalesce((sum(fiddle_daily_count) filter (where fiddle_daily_on<current_date and fiddle_daily_on>=current_date-90)),0)::integer engine_total_90
                    from fiddle_daily
                    group by engine_code
                  ) z
            ) z
        ) engines
      , ( with
            cal as (select current_date-i fiddle_daily_on from generate_series(1,1826+27) i)
          , daily as
              ( select engine_code, fiddle_daily_on, sum(fiddle_daily_count) daily_count
                from cal natural join fiddle_daily
                group by engine_code, fiddle_daily_on )
          , top6 as
              ( select engine_code, least(6, row_number() over (order by sum(daily_count) filter (where fiddle_daily_on>=current_date-90) desc nulls last)) o
                from daily
                group by engine_code )
          , points as
              ( select *
                from
                  ( select o, fiddle_daily_on d, round(avg(coalesce(sum(daily_count),0)) over (partition by o order by fiddle_daily_on rows 27 preceding))::integer a
                    from
                      generate_series(1,6) o cross join
                      cal natural left join
                      (daily natural join top6)
                    group by o, fiddle_daily_on
                  ) r
                where d>=current_date-1826 and (current_date-1-d)%7=0 )
          select json_build_object('dates',(select json_agg(d order by d) from points where o=1),'series',json_agg(a order by o))
          from (select o, json_agg(a order by d) a from points group by o) s
        ) chart
      from pg_class
      where oid = 'public.source'::regclass 
    ) z;
$$ language sql security definer set search_path=home,public,pg_temp;
--
create function redirect(text,text,text,bytea) returns bytea as $$
  select fiddle_code from legacy where engine_code=$1 and version_code=$2 and sample_name=$3 and legacy_hash=$4;
$$ language sql security definer set search_path=home,public,pg_temp;
--
create function redirect(text,text,text) returns bytea as $$
  select allowed_default_fiddle_code from allowed where engine_code=$1 and version_code=$2 and sample_name=$3;
$$ language sql security definer set search_path=home,public,pg_temp;
