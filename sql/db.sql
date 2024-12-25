revoke all on schema public from public;
revoke temporary on database fiddle from public;
alter default privileges revoke execute on routines from public;
create or replace function error(integer,text default '') returns void language plpgsql as $$begin raise exception using errcode='H0'||$1, detail=$2; end;$$;
create user lambda password :'password_lambda';

create table engine(
  engine_code text primary key
, engine_name text not null unique
, engine_default text[] not null
, engine_default_version_code text not null
, engine_separator_regex text not null default ';\s*$'
);

create table version(
  engine_code text references engine
, version_code text
, version_name text not null
, version_is_live boolean not null default false
, version_is_active boolean not null default true
, primary key (engine_code,version_code)
);

alter table engine add foreign key (engine_code,engine_default_version_code) references version(engine_code,version_code) deferrable;

create table sample(
  sample_name text primary key
, sample_description text not null
);

create table allowed(
  engine_code text
, version_code text
, sample_name text default '' references sample
, allowed_last_test_at timestamptz default timestamptz '-infinity' not null
, allowed_fail_since timestamptz
, primary key (engine_code,version_code,sample_name)
, foreign key (engine_code,version_code) references version(engine_code,version_code)
);

create table test(
  engine_code text
, version_code text
, sample_name text default '' references sample
, test_is_passed boolean not null
, test_at timestamptz default current_timestamp not null
, primary key (engine_code,version_code,sample_name,test_at)
, foreign key (engine_code,version_code,sample_name) references allowed
);

create table down(
  engine_code text
, version_code text
, sample_name text default '' references sample
, down_start_at timestamptz not null
, down_end_at timestamptz default current_timestamp not null
, primary key (engine_code,version_code,sample_name,down_start_at)
, foreign key (engine_code,version_code,sample_name) references allowed
);
create unique index down_ind on down(engine_code,version_code,sample_name) where down_end_at is null;

create table fiddle(
  engine_code text
, version_code text
, sample_name text default ''
, fiddle_hash bytea check(length(fiddle_hash)=16)
, fiddle_at timestamptz default current_timestamp not null
, fiddle_code bytea not null unique
, fiddle_input text[] not null
, fiddle_output text[]
, fiddle_output_json jsonb[]
, fiddle_is_actual boolean default true not null
, primary key (engine_code,version_code,sample_name,fiddle_hash)
, foreign key (engine_code,version_code,sample_name) references allowed(engine_code,version_code,sample_name)
, check(cardinality(fiddle_input)=cardinality(fiddle_output))
);
create index fiddle_latest on fiddle(engine_code,version_code,sample_name,fiddle_at);

create table fiddle_daily(
  engine_code text
, version_code text
, sample_name text
, fiddle_daily_on date default current_date
, fiddle_daily_count integer default 1 not null
, primary key (engine_code,version_code,sample_name,fiddle_daily_on)
, foreign key (engine_code,version_code,sample_name) references allowed
);

create table source(
  source_network cidr primary key check(family(source_network)=4 and masklen(source_network)=24)
, source_uuid uuid not null unique default gen_random_uuid()
, source_ignore_reason text
);

create table run(
  engine_code text
, version_code text
, sample_name text
, fiddle_hash bytea
, source_network cidr not null references source
, run_at timestamptz default current_timestamp not null
, foreign key (engine_code,version_code,sample_name,fiddle_hash) references fiddle
);

create table visit(
  engine_code text
, version_code text
, sample_name text
, fiddle_hash bytea
, source_network cidr not null references source
, visit_at timestamptz default current_timestamp not null
, visit_referer text
, foreign key (engine_code,version_code,sample_name,fiddle_hash) references fiddle
);
create index visit_fiddle on visit(engine_code,version_code,sample_name,fiddle_hash);
create index visit_cron on visit(engine_code,version_code,sample_name,visit_at);

create table visit_daily(
  engine_code text
, version_code text
, sample_name text
, visit_daily_on date default current_date
, visit_daily_count integer default 1 not null
, visit_daily_count_distinct_source integer
, primary key (engine_code,version_code,sample_name,visit_daily_on)
, foreign key (engine_code,version_code,sample_name) references allowed
);
create unique index visit_daily_cron on visit_daily(engine_code,version_code,sample_name,visit_daily_on) where visit_daily_count_distinct_source is null;

create table advert(
  id integer generated always as identity primary key
, words text
, image text
, url text not null
, until timestamptz
, alt text
, tagline text not null
);

create table rota(
  id integer generated always as identity primary key
, name text not null
, engine_code text references engine
, is_priority boolean default false not null
);

create table rotated(
  rota_id integer references rota
, advert_id integer references advert
, until timestamptz 
, primary key (rota_id,advert_id)
);

create or replace function gen_random_bytea(integer) returns bytea as $$
  select decode(string_agg(lpad(to_hex(width_bucket(random(), 0, 1, 256)-1),2,'0') ,''), 'hex') from generate_series(1, $1);
$$ volatile language 'sql' set search_path = 'pg_catalog';



-- in cron database:
select cron.schedule('fiddle daily stats', '0 2 * * *', $$
update visit_daily d
set visit_daily_count_distinct_source = (select count(distinct source_network)
                                         from visit v
                                         where v.engine_code=d.engine_code and v.version_code=d.version_code and v.sample_name=d.sample_name and v.visit_at>=d.visit_daily_on and v.visit_at<d.visit_daily_on+1)
where visit_daily_count_distinct_source is null and visit_daily_on<current_date;$$);

select cron.schedule('fiddle analyze', '0 2 * * *', $$analyze source;$$);

update cron.job set database = 'fiddle' WHERE jobname like 'fiddle%';


do $$
begin
  raise exception using message='foo', errcode='H0001', detail='bar';
end$$;
