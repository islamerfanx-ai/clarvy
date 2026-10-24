-- Organisation document library (decided 2026-10-24): an organisation's admins keep documents (legal, finance,
-- marketing, HR, strategy, operations) so every decision is checked against the organisation's own facts. Each
-- document has a tag, a "valid until" date and an access level. A document is read only in rooms where every member
-- may see it (the verdict quotes it to all), and the owner can untick any of them. The analysis searches the
-- passages and cites them by title and page. Looked up each time, never used to train a model.

create table org_documents (
  id             uuid primary key default gen_random_uuid(),
  workspace_id   uuid not null references workspaces (id) on delete cascade,
  title          text not null check (length(trim(title)) between 1 and 160),
  tag            text not null default 'other' check (tag in ('legal', 'finance', 'marketing', 'hr', 'strategy', 'operations', 'other')),
  valid_until    date,
  access         text not null default 'everyone' check (access in ('everyone', 'departments', 'admins')),
  department_ids uuid[] not null default '{}' check (cardinality(department_ids) <= 20),
  file_name      text check (length(file_name) <= 200),
  storage_path   text check (length(storage_path) <= 400),
  pages          int,
  chars          int not null default 0,
  uploaded_by    uuid default auth.uid() references profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (access <> 'departments' or cardinality(department_ids) > 0)
);
create index org_documents_ws_idx on org_documents (workspace_id);

-- The searchable passages (about 1,500 characters each, with the page they came from).
create table org_doc_chunks (
  doc_id uuid not null references org_documents (id) on delete cascade,
  n      int not null check (n >= 0 and n < 2000),
  page   int,
  body   text not null check (length(body) between 1 and 4000),
  primary key (doc_id, n)
);

alter table org_documents enable row level security;
alter table org_doc_chunks enable row level security;

-- May this person see this document? Admins always; others by its access level.
create function may_see_document(d org_documents, uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from workspace_members m where m.workspace_id = d.workspace_id and m.user_id = uid
                 and (m.role in ('owner', 'admin')
                      or d.access = 'everyone'
                      or (d.access = 'departments' and m.department_id = any(d.department_ids))))
$$;
revoke execute on function may_see_document(org_documents, uuid) from public, anon;
grant execute on function may_see_document(org_documents, uuid) to authenticated;

-- Members see the list of documents they may see (title, tag, dates); only admins read the passages and files.
create policy "members see the documents they may" on org_documents for select using (may_see_document(org_documents, (select auth.uid())));
create policy "admins add documents" on org_documents for insert with check (is_org_admin(workspace_id) and uploaded_by = (select auth.uid()));
create policy "admins change documents" on org_documents for update using (is_org_admin(workspace_id)) with check (is_org_admin(workspace_id));
create policy "admins remove documents" on org_documents for delete using (is_org_admin(workspace_id));
create policy "admins read passages" on org_doc_chunks for select
  using (exists (select 1 from org_documents d where d.id = doc_id and is_org_admin(d.workspace_id)));
create policy "admins add passages" on org_doc_chunks for insert
  with check (exists (select 1 from org_documents d where d.id = doc_id and is_org_admin(d.workspace_id)));
create policy "admins remove passages" on org_doc_chunks for delete
  using (exists (select 1 from org_documents d where d.id = doc_id and is_org_admin(d.workspace_id)));

create function touch_document() returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
create trigger org_documents_touch before update on org_documents for each row execute function touch_document();
revoke execute on function touch_document() from public, anon, authenticated;

-- Departments must belong to the document's organisation; at most 200 documents an organisation.
create function guard_document() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select kind from workspaces where id = new.workspace_id) <> 'organisation' then
    raise exception 'documents_are_for_organisations' using errcode = 'check_violation';
  end if;
  if cardinality(new.department_ids) > 0 and (select count(*) from departments where id = any(new.department_ids) and workspace_id = new.workspace_id)
     <> cardinality(array(select distinct unnest(new.department_ids))) then
    raise exception 'department_not_in_org' using errcode = 'check_violation';
  end if;
  if tg_op = 'INSERT' and (select count(*) from org_documents where workspace_id = new.workspace_id) >= 200 then
    raise exception 'too_many_documents' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger org_documents_guard before insert or update on org_documents for each row execute function guard_document();
revoke execute on function guard_document() from public, anon, authenticated;

-- Files live at org-docs/<organisation id>/<document id>/<file name>. Only the organisation's admins.
insert into storage.buckets (id, name, public) values ('org-docs', 'org-docs', false) on conflict (id) do nothing;
create policy "org admins read documents" on storage.objects for select
  using (bucket_id = 'org-docs' and is_org_admin(room_id_from_path(name)));
create policy "org admins upload documents" on storage.objects for insert
  with check (bucket_id = 'org-docs' and is_org_admin(room_id_from_path(name)));
create policy "org admins delete documents" on storage.objects for delete
  using (bucket_id = 'org-docs' and is_org_admin(room_id_from_path(name)));

-- ---------- Which documents a room reads ----------
-- The owner can untick documents for a room.
alter table rooms add column doc_exclude uuid[] not null default '{}' check (cardinality(doc_exclude) <= 200);

-- Documents every member of the room may see, still valid, in the room's organisation. 'excluded' when the owner
-- unticked it. For the room's people (and its assistants); the server uses room_documents_for().
create function room_documents_for(rid uuid) returns table (id uuid, title text, tag text, valid_until date, pages int, excluded boolean)
language sql stable security definer set search_path = public as $$
  select d.id, d.title, d.tag, d.valid_until, d.pages, d.id = any(r.doc_exclude)
  from rooms r join workspaces w on w.id = r.workspace_id and w.kind = 'organisation'
  join org_documents d on d.workspace_id = r.workspace_id
  where r.id = rid and (d.valid_until is null or d.valid_until >= current_date)
    and not exists (select 1 from memberships m where m.room_id = r.id and m.role <> 'observer' and not may_see_document(d, m.user_id))
  order by d.tag, d.title
$$;
revoke execute on function room_documents_for(uuid) from public, anon, authenticated;
grant execute on function room_documents_for(uuid) to service_role;
create function room_documents(rid uuid) returns table (id uuid, title text, tag text, valid_until date, pages int, excluded boolean)
language sql stable security definer set search_path = public as $$
  select * from room_documents_for(rid) where room_role(rid) is not null or assists(rid, 'view')
$$;
revoke execute on function room_documents(uuid) from public, anon;
grant execute on function room_documents(uuid) to authenticated;
