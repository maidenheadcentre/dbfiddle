drop schema if exists llms cascade;
create schema llms;
grant usage on schema llms to lambda;
set search_path to llms;
--
create function get() returns jsonb as $$
  select coalesce(json_agg(z order by code),'[]'::json)::jsonb
  from ( select engine_code code
              , ( select json_agg(to_jsonb(z)-'ordinal' order by split_part(ordinal,'.',1)::int
                                                               , nullif(split_part(ordinal,'.',2),'')::int
                                                               , code)
                  from ( select v.version_code code
                              , regexp_replace(v.version_code,'[^.0-9]','','g')::decimal::text ordinal
                              , ( select coalesce(json_agg(a.sample_name order by a.sample_name),'[]'::json)
                                  from allowed a
                                  where a.engine_code = v.engine_code
                                    and a.version_code = v.version_code
                                    and a.sample_name <> '' ) samples
                         from version v
                         where v.engine_code = e.engine_code and v.version_is_active ) z
                ) versions
         from engine e ) z
  where versions is not null;
$$ language sql security definer set search_path=llms,public,pg_temp;
--select jsonb_pretty(llms.get());
