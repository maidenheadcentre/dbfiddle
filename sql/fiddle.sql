drop schema if exists fiddle cascade;
create schema fiddle;
grant usage on schema fiddle to lambda;
set search_path to fiddle;
--
create function get(bytea) returns jsonb as $$
  with example as (
    select distinct engine_code, version_code, sample_name, fiddle_code, language_code
    from fiddle natural join batch
    where (fiddle_code, language_code) in (
      (decode('afd0da7eb0b6','hex'),'c'),
      (decode('2fdadfd5dc5d','hex'),'python')
    )
  )
  select to_jsonb((
    select z
    from( select engine_code
               , engine_name
               , version_code
               , version_name
               , sample_name
               , b.fiddle_input
               , b.fiddle_lang
               , b.fiddle_output
               , version_is_active
               , (select array_agg(language_name order by language_name)
                  from speaks s natural join language
                  where s.engine_code = f.engine_code and
                        s.version_code = f.version_code and
                        s.language_code <> 'sql') version_languages
               , ( select json_build_object('code', dv.version_code, 'name', dv.version_name)
                   from version dv natural join allowed a
                   where not v.version_is_active
                     and dv.engine_code = e.engine_code
                     and dv.version_code = e.engine_default_version_code
                     and a.sample_name = f.sample_name ) replacement
               , ( select json_build_object('code', encode(fiddle_code,'hex'), 'name', case when engine_code = f.engine_code then engine_name || ' ' || version_name else engine_name end, 'language_name', language_name)
                   from example natural join engine natural join version natural join language
                   where v.version_code = e.engine_default_version_code and
                         b.fiddle_lang is null and
                         ((engine_code,version_code) = (f.engine_code,f.version_code) or
                          not exists (select from speaks s
                                      where s.engine_code = f.engine_code and
                                            s.version_code = f.version_code and
                                            s.language_code <> 'sql'))
                   order by random() limit 1 ) example
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
                                           , (select json_agg(language_code order by language_code)
                                              from speaks s
                                              where s.engine_code = v.engine_code and
                                                    s.version_code = v.version_code) languages
                                    from version v
                                    where v.engine_code = e.engine_code) z) versions
                        from engine e) z) engines
               , (select coalesce(json_agg(to_jsonb(z)-'is_priority' order by is_priority desc, random()),'[]'::json)
                  from (select r.is_priority,a.words,a.image,a.url,a.alt,a.tagline
                        from rota r
                        cross join lateral (select words,image,url,alt,tagline
                                            from rotated d join advert a on a.id=d.advert_id
                                            where d.rota_id=r.id and
                                                  (d.until is null or d.until>current_timestamp) and
                                                  (a.until is null or a.until>current_timestamp)
                                            order by random()
                                            limit r.rota_count) a
                        where r.engine_code is null or r.engine_code=e.engine_code) z) adverts
           from fiddle f natural join engine e natural join version v
                cross join lateral
                  -- '' is the wire spelling of "the engine's own SQL"; the runners
                  -- do not accept 'sql' as a language, so it must not reach a client
                  (select coalesce(array_agg(batch_input order by batch_ordinal),'{}') fiddle_input
                        , case when count(*) filter (where language_code <> 'sql') > 0
                               then array_agg(case when language_code = 'sql' then ''
                                                   else language_code end
                                              order by batch_ordinal) end fiddle_lang
                        , case when count(*) = 0 then '{}'::text[]
                               when count(batch_output) > 0
                               then array_agg(batch_output order by batch_ordinal) end fiddle_output
                   from batch
                   where engine_code = f.engine_code and version_code = f.version_code
                     and sample_name = f.sample_name and fiddle_code = f.fiddle_code) b
           where f.fiddle_code=$1 ) z));
$$ language sql security definer set search_path=fiddle,public,pg_temp;
--
create function log(ip inet, referer text, code bytea, agent text default null, accept text default null) returns void set search_path=public,fiddle_fiddle,pg_temp as $$
  insert into source(source_network) values(set_masklen(ip::cidr,24)) on conflict do nothing;
  --
  insert into visit(engine_code,version_code,sample_name,fiddle_code,source_network,visit_referer,visit_agent,visit_accept)
  select engine_code,version_code,sample_name,code,set_masklen(ip::cidr,24),referer,agent,accept from fiddle where fiddle_code = code;
  --
  insert into visit_daily(engine_code,version_code,sample_name)
  select engine_code,version_code,sample_name from fiddle where fiddle_code = code
  on conflict (engine_code,version_code,sample_name,visit_daily_on) do update set visit_daily_count = visit_daily.visit_daily_count+1;
  --
$$ language sql security definer set search_path=fiddle,public,pg_temp;
--select jsonb_pretty(fiddle.get('\x1e8e2db09d2c'));
