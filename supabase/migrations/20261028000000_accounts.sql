-- Accounts (decided 2026-10-22): everyone signs up with Google, Microsoft or a 6-digit email code before
-- using the system, and fills in a short profile. Required at sign-up: full name, organisation, job title,
-- country (the email is verified by the sign-in itself). Optional later: phone, sector, organisation size,
-- photo, product news.

alter table profiles add column organisation text check (organisation is null or length(organisation) <= 120);
alter table profiles add column job_title    text check (job_title is null or length(job_title) <= 80);
alter table profiles add column country      text check (country is null or country ~ '^[A-Z]{2}$');
alter table profiles add column sector       text check (sector is null or length(sector) <= 60);
alter table profiles add column org_size     text check (org_size is null or org_size in ('1-10', '11-50', '51-200', '201-1000', '1000+'));
alter table profiles add column photo_url    text check (photo_url is null or (length(photo_url) <= 500 and photo_url ~ '^https://'));
alter table profiles add column news_opt_in  boolean not null default false;
alter table profiles add column completed_at timestamptz;   -- when the required fields were first filled in

-- New accounts: take the name Google or Microsoft give us.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name, email, phone, language)
  values (new.id,
          left(coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), nullif(new.raw_user_meta_data ->> 'full_name', ''), ''), 80),
          new.email,
          new.phone,
          case when new.raw_user_meta_data ->> 'language' = 'ar' then 'ar'::app_language else 'en' end);
  return new;
end $$;
revoke execute on function handle_new_user() from public, anon, authenticated;

-- A verified account's email comes from the sign-in, not from the profile form; completed_at is set once
-- the required fields are there.
create function guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  verified text;
begin
  select email into verified from auth.users where id = new.id and coalesce(is_anonymous, false) = false;
  if verified is not null then new.email := verified; end if;
  if new.completed_at is null and length(trim(new.name)) > 0 and length(trim(coalesce(new.organisation, ''))) > 0
     and length(trim(coalesce(new.job_title, ''))) > 0 and new.country is not null then
    new.completed_at := now();
  end if;
  return new;
end $$;
create trigger profiles_guard before update on profiles for each row execute function guard_profile();
revoke execute on function guard_profile() from public, anon, authenticated;

-- When someone changes or confirms their email at sign-in, the profile follows.
create function sync_profile_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles set email = new.email where id = new.id and new.email is not null and email is distinct from new.email;
  return new;
end $$;
create trigger auth_user_email_sync after update of email on auth.users for each row execute function sync_profile_email();
revoke execute on function sync_profile_email() from public, anon, authenticated;
