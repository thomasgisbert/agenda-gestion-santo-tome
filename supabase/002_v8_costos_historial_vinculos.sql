-- Agenda de Gestión v8 — costos, vínculos e historial de ediciones
-- Ejecutar en Supabase > SQL Editor sobre el proyecto ya configurado con setup.sql.

begin;

alter table public.tasks add column if not exists cost_amount numeric(14,2) not null default 0;
alter table public.tasks add column if not exists linked_task_id uuid references public.tasks(id) on delete set null;

do $$ begin
  alter table public.tasks add constraint tasks_cost_amount_nonnegative check (cost_amount >= 0);
exception when duplicate_object then null; end $$;

create index if not exists tasks_linked_task_id_idx on public.tasks(linked_task_id);

create table if not exists public.task_versions (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  version_no integer not null,
  task_date date not null,
  area_id text not null,
  title text not null,
  info text,
  critical text,
  cost_amount numeric(14,2) not null default 0,
  linked_task_id uuid,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now(),
  unique(task_id, version_no)
);

create index if not exists task_versions_task_id_idx on public.task_versions(task_id);
create index if not exists task_versions_changed_at_idx on public.task_versions(changed_at desc);

create or replace function public.capture_task_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  next_version integer;
begin
  select coalesce(max(tv.version_no),0)+1 into next_version
  from public.task_versions tv where tv.task_id = old.id;

  insert into public.task_versions(
    task_id,version_no,task_date,area_id,title,info,critical,cost_amount,linked_task_id,changed_by,changed_at
  ) values (
    old.id,next_version,old.task_date,old.area_id,old.title,old.info,old.critical,
    coalesce(old.cost_amount,0),old.linked_task_id,new.updated_by,now()
  );
  return new;
end;
$$;

drop trigger if exists tasks_capture_version on public.tasks;
create trigger tasks_capture_version
before update on public.tasks
for each row
when (
  old.task_date is distinct from new.task_date or
  old.area_id is distinct from new.area_id or
  old.title is distinct from new.title or
  old.info is distinct from new.info or
  old.critical is distinct from new.critical or
  old.cost_amount is distinct from new.cost_amount or
  old.linked_task_id is distinct from new.linked_task_id
)
execute function public.capture_task_version();

alter table public.task_versions enable row level security;
revoke all on table public.task_versions from anon;
revoke all on table public.task_versions from authenticated;
grant select on table public.task_versions to authenticated;

drop policy if exists task_versions_select on public.task_versions;
create policy task_versions_select
on public.task_versions
for select
to authenticated
using (
  public.current_app_role() in ('admin','manager')
  or exists (
    select 1 from public.tasks t
    where t.id = task_versions.task_id
      and t.created_by = (select auth.uid())
  )
);

-- El campo antiguo "costs" se conserva por compatibilidad, pero la app v8 usa cost_amount.

commit;