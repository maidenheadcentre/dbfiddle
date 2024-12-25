drop schema if exists fiddle cascade;
create schema fiddle;
grant usage on schema fiddle to lambda;
set search_path to fiddle;
--
create function get(bytea) returns jsonb as $$
  select to_jsonb((
    select z
    from( select engine_code
               , engine_name
               , version_code
               , version_name
               , sample_name
               , fiddle_input
               , fiddle_output_json fiddle_output
               , version_is_active
               , (select json_agg(z order by engine_name)
                  from (select engine_code
                             , engine_name
                             , engine_separator_regex
                             , case when e.engine_code = f.engine_code then f.version_code else engine_default_version_code end engine_version_code
                             , (select json_agg(z order by split_part(version_ordinal,'.',1)::int, nullif(split_part(version_ordinal,'.',2),'')::int, version_name)
                                from (select version_code
                                           , version_is_active
                                           , version_name
                                           , regexp_replace(version_code,'[^.0-9]','','g')::decimal::text version_ordinal
                                           , (select json_agg(z order by sample_name)
                                              from (select sample_name
                                                         , sample_description
                                                    from allowed a natural join sample
                                                    where a.engine_code = v.engine_code and 
                                                          a.version_code = v.version_code) z) samples
                                    from version v
                                    where v.engine_code = e.engine_code) z) versions
                        from engine e) z) engines
               , (select coalesce(json_agg(to_jsonb(z)-'id'-'is_priority' order by is_priority desc, random()),'[]'::json)
                  from (select distinct on (r.id,r.is_priority)
                               r.id,r.is_priority,a.words,a.image,a.url,a.alt,a.tagline
                        from rota r join rotated d on d.rota_id=r.id join advert a on a.id=d.advert_id
                        where (r.engine_code is null or r.engine_code=e.engine_code) and
                              (d.until is null or d.until>current_timestamp) and 
                              (a.until is null or a.until>current_timestamp)
                        order by r.id,r.is_priority,random() ) z) adverts
           from fiddle f natural join engine e natural join version v
           where fiddle_code=$1 ) z));
$$ language sql security definer set search_path=fiddle,public,pg_temp;
--
create function log(ip inet, referer text, code bytea) returns void set search_path=public,fiddle_fiddle,pg_temp as $$
  insert into source(source_network) values(set_masklen(ip::cidr,24)) on conflict do nothing;
  --
  insert into visit(engine_code,version_code,sample_name,fiddle_hash,source_network,visit_referer)
  select engine_code,version_code,sample_name,fiddle_hash,set_masklen(ip::cidr,24),referer from fiddle where fiddle_code = code;
  --
  insert into visit_daily(engine_code,version_code,sample_name)
  select engine_code,version_code,sample_name from fiddle where fiddle_code = code
  on conflict (engine_code,version_code,sample_name,visit_daily_on) do update set visit_daily_count = visit_daily.visit_daily_count+1;
  --
$$ language sql security definer set search_path=fiddle,public,pg_temp;
--select jsonb_pretty(fiddle.get('\x1e8e2db09d2c'));
