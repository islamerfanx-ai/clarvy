-- Departments on the question (decided 2026-10-24): in an organisation, a room names the departments it concerns
-- (one leads). It shapes who is suggested to invite (the department's head and people), the organisation memory
-- the analysis reads, and the organisation's view of decisions by department.

-- Each department can have a head (set by an organisation admin; must be a member of the organisation).
alter table departments add column head_id uuid references profiles (id) on delete set null;
create function guard_department_head() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.head_id is not null and not exists (select 1 from workspace_members m where m.workspace_id = new.workspace_id and m.user_id = new.head_id) then
    raise exception 'head_not_member' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger departments_guard_head before insert or update of head_id on departments for each row execute function guard_department_head();
revoke execute on function guard_department_head() from public, anon, authenticated;

-- The room's departments: the first is the lead. They must belong to the room's organisation.
alter table rooms add column department_ids uuid[] not null default '{}' check (cardinality(department_ids) <= 6);
create function guard_room_departments() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if cardinality(new.department_ids) > 0 and (tg_op = 'INSERT' or new.department_ids is distinct from old.department_ids) then
    if (select count(*) from departments d where d.id = any(new.department_ids) and d.workspace_id = new.workspace_id)
       <> cardinality(array(select distinct unnest(new.department_ids))) then
      raise exception 'department_not_in_org' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger rooms_guard_departments before insert or update of department_ids on rooms for each row execute function guard_room_departments();
revoke execute on function guard_room_departments() from public, anon, authenticated;
create index rooms_departments_idx on rooms using gin (department_ids);

-- Department names for everyone in the room (members may not belong to the organisation themselves).
create function room_departments(rid uuid) returns table (id uuid, name text, lead boolean)
language sql stable security definer set search_path = public as $$
  select d.id, d.name, d.id = r.department_ids[1]
  from rooms r cross join lateral unnest(r.department_ids) with ordinality u(did, pos)
  join departments d on d.id = u.did
  where r.id = rid and room_role(rid) is not null
  order by u.pos
$$;
revoke execute on function room_departments(uuid) from public, anon;
grant execute on function room_departments(uuid) to authenticated;

-- The colleague directory now says who heads each department.
drop function org_directory(uuid);
create function org_directory(wid uuid) returns table (user_id uuid, name text, job_title text, email text, department_id uuid, department text,
                                                       role workspace_role, is_head boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.job_title, p.email, m.department_id, d.name, m.role,
         exists (select 1 from departments h where h.workspace_id = wid and h.head_id = p.id)
  from workspace_members m join profiles p on p.id = m.user_id left join departments d on d.id = m.department_id
  join workspaces w on w.id = m.workspace_id
  where m.workspace_id = wid and w.kind = 'organisation' and is_workspace_member(wid)
  order by p.name
$$;
revoke execute on function org_directory(uuid) from public, anon;
grant execute on function org_directory(uuid) to authenticated;

-- The admins' room list carries the departments (names, lead first).
drop function org_rooms(uuid);
create function org_rooms(wid uuid) returns table (id uuid, question text, status room_status, owner_name text, created_at timestamptz,
                                                   members bigint, answered bigint, decided_at timestamptz, final_label text, review_date date,
                                                   departments text[])
language sql stable security definer set search_path = public as $$
  select r.id, r.question, r.status, p.name, r.created_at,
         (select count(*) from memberships x where x.room_id = r.id and x.role <> 'observer'),
         (select count(*) from inputs i where i.room_id = r.id),
         a.decided_at,
         (select o->>'label' from jsonb_array_elements(r.options) o where o->>'id' = a.final_option),
         r.review_date,
         array(select d.name from unnest(r.department_ids) with ordinality u(did, pos) join departments d on d.id = u.did order by u.pos)
  from rooms r join profiles p on p.id = r.owner_id
  left join lateral (select x.decided_at, x.final_option from analyses x where x.room_id = r.id order by x.created_at desc limit 1) a on true
  where r.workspace_id = wid and is_org_admin(wid)
  order by r.created_at desc
$$;
revoke execute on function org_rooms(uuid) from public, anon;
grant execute on function org_rooms(uuid) to authenticated;
