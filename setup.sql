-- SU Dresses: جداول ودوال وصلاحيات. شغّليه مرة واحدة في Supabase ← SQL Editor.

create table if not exists public.docs (
  collection text not null,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (collection, id)
);
create index if not exists docs_col_idx on public.docs (collection);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  phone text unique not null,
  name text not null,
  role text not null default 'staff' check (role in ('admin','staff')),
  active boolean not null default false,
  created_at timestamptz not null default now()
);

-- أول حساب بيتعمل بيبقى مديرة ومفعّل. باقي الحسابات بتتفعّل من المديرة.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare first_user boolean;
begin
  select not exists (select 1 from public.profiles) into first_user;
  insert into public.profiles (id, phone, name, role, active)
  values (new.id, split_part(new.email,'@',1),
          coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
          case when first_user then 'admin' else 'staff' end,
          first_user);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.has_users() returns boolean
language sql security definer set search_path = public as $$
  select exists (select 1 from public.profiles) $$;
grant execute on function public.has_users() to anon, authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and active) $$;
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active) $$;

-- تعديل جزئي لمستند (بيدمج الحقول). بيحترم نفس صلاحيات الجدول.
create or replace function public.patch_doc(p_collection text, p_id text, p_patch jsonb) returns void
language plpgsql security invoker as $$
begin
  update public.docs set data = data || p_patch, updated_at = now()
  where collection = p_collection and id = p_id;
  if not found then raise exception 'doc not found'; end if;
end $$;

alter table public.docs enable row level security;
alter table public.profiles enable row level security;

-- profiles: كل موظف مفعّل يشوف الفريق. المديرة بس تعدّل.
drop policy if exists p_read on public.profiles;
create policy p_read on public.profiles for select using (id = auth.uid() or public.is_staff());
drop policy if exists p_upd on public.profiles;
create policy p_upd on public.profiles for update using (public.is_admin()) with check (public.is_admin());

-- docs: الصلاحيات حسب المجموعة
-- المديرة: كل حاجة
drop policy if exists d_admin on public.docs;
create policy d_admin on public.docs for all using (public.is_admin()) with check (public.is_admin());

-- الموظفة المفعّلة: قراءة وكتابة العمليات العادية
drop policy if exists d_staff_read on public.docs;
create policy d_staff_read on public.docs for select using (
  public.is_staff() and collection in ('items','photos','clients','bookings','payments','notes','cfg'));
drop policy if exists d_staff_write on public.docs;
create policy d_staff_write on public.docs for insert with check (
  public.is_staff() and collection in ('items','photos','clients','bookings','payments','notes','expenses','log'));
drop policy if exists d_staff_upd on public.docs;
create policy d_staff_upd on public.docs for update using (
  public.is_staff() and collection in ('items','photos','clients','bookings','notes'))
  with check (public.is_staff() and collection in ('items','photos','clients','bookings','notes'));
drop policy if exists d_staff_del on public.docs;
create policy d_staff_del on public.docs for delete using (
  public.is_staff() and collection in ('notes'));
-- المصاريف وأسعار الشراء وسجل الحركة: الموظفة تقدر تضيف مصروف، لكن مش بتقراها ولا بتعدلها.

-- تحديث لحظي لكل الأجهزة
alter table public.docs replica identity full;
do $$ begin
  begin alter publication supabase_realtime add table public.docs; exception when duplicate_object then null; end;
end $$;
