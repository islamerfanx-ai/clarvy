# Privacy and validation checks for the Decision Rooms schema, on a throwaway embedded Postgres.
#   python3 -m venv .venv && .venv/bin/pip install pgserver "psycopg[binary]"
#   .venv/bin/python supabase/tests/test_rls.py supabase/migrations/*.sql
"""Run the Decision Rooms migration on embedded Postgres with Supabase stubs, then test RLS."""
import sys, tempfile, uuid, pgserver, psycopg

MIGRATIONS = sorted(sys.argv[1:])
STUB = """
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth; create schema storage;
create table auth.users (id uuid primary key, email text, phone text, raw_user_meta_data jsonb default '{}', is_anonymous boolean default false, created_at timestamptz default now(), last_sign_in_at timestamptz);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
create table storage.buckets (id text primary key, name text, public boolean);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
grant all on storage.objects to anon, authenticated;
grant usage on schema public, auth, storage to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated;
"""

d = tempfile.mkdtemp()
srv = pgserver.get_server(d, cleanup_mode="stop")
conn = psycopg.connect(srv.get_uri(), autocommit=True)
def db(sql):
    with conn.cursor() as cur:
        cur.execute(sql)
db(STUB)
try:
    for m in MIGRATIONS: db(open(m).read())
except Exception as e:
    print("MIGRATION ERROR:", e); sys.exit(1)
print("migration applied")

A, B, C, D, E = (str(uuid.uuid4()) for _ in range(5))
db("".join(f"insert into auth.users (id,email,raw_user_meta_data) values ('{u}','{n}@x.test','{{\"name\":\"{n}\"}}');"
           for u, n in zip((A, B, C, D, E), "ABCDE")))

def as_user(u, sql, anonymous=False):
    """Run one statement as user u. Returns 'STATUS', rows as 'a | b' lines, or 'ERROR: ...'."""
    try:
        with conn.transaction(), conn.cursor() as cur:
            cur.execute("set local role authenticated")
            cur.execute("select set_config('request.jwt.claim.sub', %s, true)", (u,))
            cur.execute("select set_config('request.jwt.claims', %s, true)", (f'{{"sub":"{u}","is_anonymous":{str(anonymous).lower()}}}',))
            cur.execute(sql)
            out = cur.statusmessage
            if cur.description:
                out += "\n" + "\n".join(" | ".join(str(v) for v in r) for r in cur.fetchall())
            return out + "\n"
    except Exception as e:
        return f"ERROR: {e}"

def server(sql):
    """Run one statement as the server (no row-level security), same output shape as as_user."""
    try:
        with conn.transaction(), conn.cursor() as cur:
            cur.execute(sql)
            out = cur.statusmessage
            if cur.description:
                out += "\n" + "\n".join(" | ".join(str(v) for v in r) for r in cur.fetchall())
            return out + "\n"
    except Exception as e:
        return f"ERROR: {e}"

results = []
def check(name, out, expect):
    ok = expect in out
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "\n" + out))

W = str(uuid.uuid4()); R = str(uuid.uuid4())
crit = '[{"id":"cash","label":"Cash risk","weight":40},{"id":"upside","label":"Upside","weight":60}]'
opts = '[{"id":"a","label":"Open now"},{"id":"b","label":"Wait a year"}]'
check("owner creates workspace", as_user(A, f"insert into workspaces (id,name,owner_id) values ('{W}','Acme','{A}')"), "INSERT 0 1")
check("owner opens room", as_user(A, f"insert into rooms (id,workspace_id,type,question,options,criteria,owner_id) values ('{R}','{W}','business','Open in Jeddah?','{opts}','{crit}','{A}')"), "INSERT 0 1")
check("owner auto-joined", as_user(A, f"select role from memberships where room_id='{R}'"), "owner")
check("owner adds members", as_user(A, f"insert into memberships (room_id,user_id,role) values ('{R}','{B}','member'),('{R}','{C}','member'),('{R}','{D}','observer')"), "INSERT 0 3")
check("member can't add people", as_user(B, f"insert into memberships (room_id,user_id) values ('{R}','{E}')"), "row-level security")
check("outsider can't see room", as_user(E, f"select count(*) from rooms where id='{R}'"), "\n0\n")

good = '{"cash":70,"upside":30}'
check("member gives input", as_user(B, f"insert into inputs (room_id,user_id,weights,risk_appetite,gut_pick,concern) values ('{R}','{B}','{good}','safe','b','Cash is thin')"), "INSERT 0 1")
check("member reads own input", as_user(B, f"select concern from inputs where room_id='{R}'"), "Cash is thin")
check("other member can't read it", as_user(C, f"select count(*) from inputs where room_id='{R}'"), "\n0\n")
check("owner can't read it", as_user(A, f"select count(*) from inputs where room_id='{R}'"), "\n0\n")
check("can't write input as someone else", as_user(C, f"insert into inputs (room_id,user_id,weights,risk_appetite) values ('{R}','{B}','{good}','safe')"), "row-level security")
check("weights must sum to 100", as_user(C, f"insert into inputs (room_id,user_id,weights,risk_appetite) values ('{R}','{C}','{{\"cash\":70,\"upside\":29}}','bold')"), "weights_must_sum_100")
check("weights must cover criteria", as_user(C, f"insert into inputs (room_id,user_id,weights,risk_appetite) values ('{R}','{C}','{{\"cash\":100}}','bold')"), "weights_must_cover_criteria")
check("weights must be whole", as_user(C, f"insert into inputs (room_id,user_id,weights,risk_appetite) values ('{R}','{C}','{{\"cash\":50.5,\"upside\":49.5}}','bold')"), "weights_must_be_whole")
check("gut pick must be an option", as_user(C, f"insert into inputs (room_id,user_id,weights,risk_appetite,gut_pick) values ('{R}','{C}','{good}','bold','z')"), "gut_pick_not_an_option")
check("observer can't give input", as_user(D, f"insert into inputs (room_id,user_id,weights,risk_appetite) values ('{R}','{D}','{good}','bold')"), "observers_do_not_give_input")
check("outsider can't give input", as_user(E, f"insert into inputs (room_id,user_id,weights,risk_appetite) values ('{R}','{E}','{good}','bold')"), "ERROR")
check("member edits own input", as_user(B, f"update inputs set concern='Cash is very thin' where room_id='{R}' and user_id='{B}'"), "UPDATE 1")

check("member can't promote self", as_user(B, f"update memberships set role='owner' where room_id='{R}' and user_id='{B}'"), "only_owner_changes_roles")
check("member gives own consent", as_user(B, f"update memberships set named_view_consent=true where room_id='{R}' and user_id='{B}'"), "UPDATE 1")
check("owner can't consent for others", as_user(A, f"update memberships set named_view_consent=true where room_id='{R}' and user_id='{C}'"), "consent_is_personal")
check("owner can't hand over ownership", as_user(A, f"update memberships set role='owner' where room_id='{R}' and user_id='{C}'"), "only_owner_changes_roles")

check("roster shows ticks", as_user(C, f"select name, submitted from room_roster('{R}') where submitted"), "B | True")
check("roster empty for outsiders", as_user(E, f"select count(*) from room_roster('{R}')"), "\n0\n")
check("profiles: no peeking at co-member email", as_user(C, f"select count(*) from profiles where id='{B}'"), "\n0\n")

db(f"insert into calendar_links (user_id,provider,token_ciphertext) values ('{B}','google','secret')")
check("calendar token never readable", as_user(B, "select token_ciphertext from calendar_links"), "permission denied")
check("calendar link listable", as_user(B, "select provider from calendar_links"), "google")

db(f"insert into analyses (room_id, verdict) values ('{R}', '{{\"call\":\"b\"}}')")
check("member can't decide verdict", as_user(B, f"select decide_verdict('{R}','accepted')"), "only_owner_decides")
check("override needs a real option", as_user(A, f"select decide_verdict('{R}','overridden','Cash first','zzz')"), "override_needs_option")
check("override needs a reason", as_user(A, f"select decide_verdict('{R}','overridden','  ','b')"), "check constraint")
check("owner overrides with reason", as_user(A, f"select decide_verdict('{R}','overridden','Cash first this year','b')"), "SELECT 1")
check("override is the final option", as_user(A, f"select final_option, override_reason from analyses where room_id='{R}'"), "b | Cash first this year")
check("inputs locked once decided", as_user(B, f"update inputs set concern='late' where room_id='{R}' and user_id='{B}'"), "room_not_open")

check("signoff then counts", (as_user(C, f"insert into signoffs (room_id,user_id,stance) values ('{R}','{C}','object')") + as_user(C, f"select stance, n from signoff_counts('{R}')")), "object | 1")
check("others can't read who objected", as_user(A, f"select count(*) from signoffs where room_id='{R}'"), "\n0\n")

check("storage: member reads room file", as_user(B, f"select count(*) from storage.objects where bucket_id='room-files' and name like '{R}/%'"), "SELECT 1")
check("storage: member can't upload", as_user(B, f"insert into storage.objects (bucket_id,name) values ('room-files','{R}/x.pdf')"), "row-level security")
check("storage: owner uploads", as_user(A, f"insert into storage.objects (bucket_id,name) values ('room-files','{R}/x.pdf')"), "INSERT 0 1")
check("storage: junk path is denied, not an error", as_user(A, "insert into storage.objects (bucket_id,name) values ('room-files','nope/x.pdf')"), "row-level security")

# ---------- Invites and room validation (20261013000000_room_invites.sql) ----------
F = str(uuid.uuid4())
def anon(sql):
    try:
        with conn.transaction(), conn.cursor() as cur:
            cur.execute("set local role anon"); cur.execute(sql)
            return cur.statusmessage + "\n" + "\n".join(" | ".join(str(v) for v in r) for r in cur.fetchall()) + "\n"
    except Exception as e:
        return f"ERROR: {e}"
db(f"insert into auth.users (id,email) values ('{F}','f@x.test')")
R2 = str(uuid.uuid4())
check("owner opens a second room", as_user(A, f"insert into rooms (id,workspace_id,type,question,options,criteria,owner_id) values ('{R2}','{W}','finance','Loan or equity?','{opts}','{crit}','{A}')"), "INSERT 0 1")
check("room needs 2+ options", as_user(A, f"insert into rooms (workspace_id,type,question,options,criteria,owner_id) values ('{W}','finance','x','[{{\"id\":\"a\",\"label\":\"A\"}}]','{crit}','{A}')"), "room_needs_2_to_6_options")
check("criteria weights must sum to 100", as_user(A, f"insert into rooms (workspace_id,type,question,options,criteria,owner_id) values ('{W}','finance','x','{opts}','[{{\"id\":\"a\",\"label\":\"A\",\"weight\":50}},{{\"id\":\"b\",\"label\":\"B\",\"weight\":40}}]','{A}')"), "criteria_weights_must_sum_100")
check("ids must be unique", as_user(A, f"insert into rooms (workspace_id,type,question,options,criteria,owner_id) values ('{W}','finance','x','[{{\"id\":\"a\",\"label\":\"A\"}},{{\"id\":\"a\",\"label\":\"B\"}}]','{crit}','{A}')"), "room_ids_must_be_unique")
check("criteria frozen once input exists", as_user(A, f"update rooms set criteria='[{{\"id\":\"x\",\"label\":\"X\",\"weight\":50}},{{\"id\":\"y\",\"label\":\"Y\",\"weight\":50}}]' where id='{R}'"), "room_has_inputs")
check("owner edits criteria before any input", as_user(A, f"update rooms set criteria='[{{\"id\":\"x\",\"label\":\"X\",\"weight\":50}},{{\"id\":\"y\",\"label\":\"Y\",\"weight\":50}}]' where id='{R2}'"), "UPDATE 1")
check("member can't create invites", as_user(B, f"insert into invites (room_id,created_by) values ('{R}','{B}')"), "row-level security")
check("owner creates invite", as_user(A, f"insert into invites (token,room_id,created_by) values ('tok2','{R2}','{A}')"), "INSERT 0 1")
check("owner can't invite an owner", as_user(A, f"insert into invites (token,room_id,role,created_by) values ('tok3','{R2}','owner','{A}')"), "check constraint")
check("signed-out preview shows the question", anon("select question, usable from invite_preview('tok2')"), "Loan or equity? | True")
check("preview of a bad token is empty", anon("select count(*) from invite_preview('nope')"), "\n0\n")
check("signed-out can't join", anon("select join_room('tok2')"), "permission denied")
check("outsider can't see room before joining", as_user(F, f"select count(*) from rooms where id='{R2}'"), "\n0\n")
check("join with a link", as_user(F, "select join_room('tok2', true)"), R2)
check("joined: room now visible", as_user(F, f"select question from rooms where id='{R2}'"), "Loan or equity?")
check("joined as member with consent", as_user(F, f"select role, named_view_consent from memberships where room_id='{R2}' and user_id='{F}'"), "member | True")
check("joining twice is harmless", as_user(F, "select join_room('tok2')"), R2)
check("invite use counted once", as_user(A, "select uses from invites where token='tok2'"), "\n1\n")
check("bad token is rejected", as_user(F, "select join_room('nope')"), "invite_not_found")
check("members can't list invite tokens", as_user(F, f"select count(*) from invites where room_id='{R2}'"), "\n0\n")
as_user(A, "update invites set revoked=true where token='tok2'")
check("revoked link stops working", as_user(E, "select join_room('tok2')"), "invite_expired")
check("revoked link shows as unusable", anon("select usable from invite_preview('tok2')"), "False")
check("links to a decided room stop working", (as_user(A, f"insert into invites (token,room_id,created_by) values ('tok4','{R}','{A}')") + as_user(E, "select join_room('tok4')")), "invite_expired")

# ---------- The simple journey (20261014000000_room_journey.sql) ----------
G = str(uuid.uuid4())
db(f"insert into auth.users (id) values ('{G}')")
check("trial: name-only account can open a workspace", as_user(G, f"insert into workspaces (id,name,owner_id) values ('{G}','Guest ws','{G}')", anonymous=True), "INSERT 0 1")
check("name-only member can set their name", as_user(G, f"update profiles set name='Guest' where id='{G}'", anonymous=True), "UPDATE 1")
check("owner makes a fresh invite", as_user(A, f"insert into invites (token,room_id,created_by) values ('tok5','{R2}','{A}')"), "INSERT 0 1")
check("name-only member joins with a link", as_user(G, "select join_room('tok5')", anonymous=True), R2)
check("name-only member gives input with ratings", as_user(G, f"insert into inputs (room_id,user_id,weights,ratings,risk_appetite,gut_pick) values ('{R2}','{G}','{{\"x\":75,\"y\":25}}','{{\"x\":5,\"y\":2}}','bold','a')", anonymous=True), "INSERT 0 1")
check("trial: can't open a room in someone else's workspace", as_user(G, f"insert into rooms (workspace_id,type,question,options,criteria,owner_id) values ('{W}','business','x','{opts}','{crit}','{G}')", anonymous=True), "row-level security")
check("my rooms lists the room with counts", as_user(G, f"select question, role, members, submitted, i_submitted, has_verdict from my_rooms() where id='{R2}'", anonymous=True), "Loan or equity? | member | 3 | 1 | True | False")
check("my rooms: owner sees status", as_user(A, f"select status from my_rooms() where id='{R}'"), "decided")
check("my rooms empty for outsiders", as_user(E, "select count(*) from my_rooms()"), "\n0\n")
check("no sign-off before the call is settled", as_user(G, f"insert into signoffs (room_id,user_id,stance) values ('{R2}','{G}','agree')", anonymous=True), "row-level security")
check("verdict needs an analysis first", as_user(A, f"select decide_verdict('{R2}','accepted')"), "no_verdict_yet")
db(f"insert into analyses (room_id, verdict) values ('{R2}', '{{\"call\":\"b\"}}')")
check("accept takes Clarvy's call", (as_user(A, f"select decide_verdict('{R2}','accepted')") + as_user(A, f"select final_option, owner_decision from analyses where room_id='{R2}'")), "b | accepted")
check("sign-off once settled", as_user(G, f"insert into signoffs (room_id,user_id,stance) values ('{R2}','{G}','agree')", anonymous=True), "INSERT 0 1")

# ---------- Models, RAPID and the open trial (20261016000000_models_trial.sql) ----------
R3 = str(uuid.uuid4())
check("trial: name-only account opens a room in its own workspace", as_user(G, f"insert into rooms (id,workspace_id,type,question,options,criteria,owner_id,model,rapid) values ('{R3}','{G}','business','Hire a COO?','{opts}','{crit}','{G}','wrap',true)", anonymous=True), "INSERT 0 1")
check("room keeps its model", as_user(G, f"select model, rapid from rooms where id='{R3}'", anonymous=True), "wrap | True")
check("unknown model is rejected", as_user(G, f"update rooms set model='astrology' where id='{R3}'", anonymous=True), "check constraint")
check("email must look like an email", as_user(G, f"update profiles set email='not-an-email' where id='{G}'", anonymous=True), "profiles_email_shape")
check("guest saves their email", as_user(G, f"update profiles set email='guest@x.test' where id='{G}'", anonymous=True), "UPDATE 1")
check("owner adds people to the RAPID room", as_user(G, f"insert into memberships (room_id,user_id,role) values ('{R3}','{B}','member'),('{R3}','{C}','member')", anonymous=True), "INSERT 0 2")
check("member can't make themselves approver", as_user(B, f"update memberships set rapid_role='approver' where room_id='{R3}' and user_id='{B}'"), "only_owner_changes_roles")
check("owner names an approver", as_user(G, f"update memberships set rapid_role='approver' where room_id='{R3}' and user_id='{B}'", anonymous=True), "UPDATE 1")
check("roster shows RAPID roles", as_user(C, f"select name, rapid_role from room_roster('{R3}') where rapid_role is not null"), "B | approver")
check("non-approver can't object", as_user(C, f"insert into objections (room_id,user_id,reason) values ('{R3}','{C}','no')"), "row-level security")
O = str(uuid.uuid4())
check("approver objects", as_user(B, f"insert into objections (id,room_id,user_id,reason) values ('{O}','{R3}','{B}','Legal has not cleared option B')"), "INSERT 0 1")
check("room sees the objection", as_user(C, f"select reason, status from objections where room_id='{R3}'"), "Legal has not cleared option B | open")
check("member can't override", as_user(C, f"select override_objection('{O}','because')"), "only_owner_decides")
check("override needs a reason", as_user(G, f"select override_objection('{O}','  ')", anonymous=True), "need_reason")
check("owner overrides on the record", (as_user(G, f"select override_objection('{O}','Cleared by outside counsel')", anonymous=True) + as_user(C, f"select status, override_reason from objections where id='{O}'")), "overridden | Cleared by outside counsel")
O2 = str(uuid.uuid4())
as_user(B, f"insert into objections (id,room_id,user_id,reason) values ('{O2}','{R3}','{B}','Budget not approved')")
check("someone else can't withdraw it", as_user(C, f"select withdraw_objection('{O2}')"), "objection_not_found")
check("approver withdraws their own", (as_user(B, f"select withdraw_objection('{O2}')") + as_user(B, f"select status from objections where id='{O2}'")), "withdrawn")
check("no objections in rooms without RAPID", as_user(A, f"insert into objections (room_id,user_id,reason) values ('{R}','{A}','x')"), "row-level security")

# ---------- Custom categories (20261017000000_custom_category.sql) ----------
R4 = str(uuid.uuid4())
check("custom room needs a name", as_user(G, f"insert into rooms (workspace_id,type,question,options,criteria,owner_id) values ('{G}','custom','Move the warehouse?','{opts}','{crit}','{G}')", anonymous=True), "rooms_custom_needs_label")
check("custom room with a name", as_user(G, f"insert into rooms (id,workspace_id,type,type_label,question,options,criteria,owner_id) values ('{R4}','{G}','custom','Logistics','Move the warehouse?','{opts}','{crit}','{G}')", anonymous=True), "INSERT 0 1")
check("my rooms shows the custom name", as_user(G, f"select type, type_label from my_rooms() where id='{R4}'", anonymous=True), "custom | Logistics")
as_user(G, f"insert into invites (token,room_id,created_by) values ('tok6','{R4}','{G}')", anonymous=True)
check("invite preview shows the custom name", anon("select type, type_label from invite_preview('tok6')"), "custom | Logistics")
check("category name has a length limit", as_user(G, f"update rooms set type_label='{'x'*41}' where id='{R4}'", anonymous=True), "check constraint")

# ---------- Links and reports (20261018000000_links_reports.sql) ----------
check("owner adds room links", as_user(A, f"""update rooms set links='[{{"url":"https://example.org/report"}}]' where id='{R2}'"""), "UPDATE 1")
check("member saves private links with answers", as_user(C, f"insert into inputs (room_id,user_id,weights,risk_appetite,gut_pick,links) values ('{R3}','{C}','{good}','safe','a',array['https://example.org/a'])"), "INSERT 0 1")
check("other members can't read those links", as_user(B, f"select count(*) from inputs where room_id='{R3}' and user_id='{C}'"), "\n0\n")
check("at most 5 links per member", as_user(C, f"update inputs set links=array['1','2','3','4','5','6'] where room_id='{R3}' and user_id='{C}'"), "check constraint")
check("member can't make a report link", as_user(F, f"insert into report_shares (room_id,created_by) values ('{R2}','{F}')"), "row-level security")
check("owner makes a report link", as_user(A, f"insert into report_shares (token,room_id,created_by) values ('rep1','{R2}','{A}')"), "INSERT 0 1")
rep = anon("select report_by_token('rep1')")
check("anyone with the link reads the report", rep, "Loan or equity?")
check("report carries the verdict and counts", rep, "'final_option': 'b'")
check("report never includes answers or member links", ("weights" not in rep and "example.org/a" not in rep and "guest@x.test" not in rep) and "ok" or rep, "ok")
check("can't call the raw report function", anon(f"select room_report('{R2}')"), "permission denied")
check("member reads report in the room", as_user(F, f"select report_for_member('{R2}') is not null"), "True")
check("outsider gets nothing by room id", as_user(E, f"select report_for_member('{R2}') is null"), "True")
as_user(A, "update report_shares set revoked=true where token='rep1'")
check("switched-off link shows nothing", anon("select report_by_token('rep1') is null"), "True")

# ---------- Hardening (20261019000000_hardening.sql) ----------
check("people can't count their own usage", as_user(A, f"select use_quota('{A}','decide',100)"), "permission denied")
check("people can't read usage counts", as_user(A, "select count(*) from usage_counts"), "permission denied")
check("server: first use is within the limit", server(f"select use_quota('{A}','decide',2)"), "True")
server(f"select use_quota('{A}','decide',2)")
check("server: third use goes over a limit of 2", server(f"select use_quota('{A}','decide',2)"), "False")
check("signed-out can't call policy helpers", anon(f"select room_role('{R2}')"), "permission denied")
check("signed-out can't call trigger functions", anon("select validate_room()"), "permission denied")
check("policies read auth.uid() once per query", server("select count(*) from pg_policies where schemaname='public' and replace(coalesce(qual,'') || coalesce(with_check,''), 'SELECT auth.uid()', '') like '%auth.uid()%'"), "\n0\n")
check("rooms still readable after the policy rewrite", as_user(F, f"select count(*) from rooms where id='{R2}'"), "\n1\n")
check("trip tables closed", as_user(A, "select count(*) from trip_options"), "permission denied")

# ---------- Who's in the room (20261020000000_room_roles.sql) ----------
R5 = str(uuid.uuid4())
roles = '[{"id":"r1","title":"CFO","max":1,"ask":"Add the cost numbers.","rapid":"approver"},{"id":"r2","title":"Director","max":null,"ask":""}]'
check("room with organisation type and roles", as_user(G, f"insert into rooms (id,workspace_id,type,question,options,criteria,owner_id,org_type,roles,rapid) values ('{R5}','{G}','business','Enter Egypt?','{opts}','{crit}','{G}','corporation','{roles}',true)", anonymous=True), "INSERT 0 1")
check("bad role shape is rejected", as_user(G, f"""update rooms set roles='[{{"id":"r1","title":""}}]' where id='{R5}'""", anonymous=True), "rooms_roles_shape")
check("unknown organisation type is rejected", as_user(G, f"update rooms set org_type='cult' where id='{R5}'", anonymous=True), "check constraint")
check("owner makes a role link with a limit", as_user(G, f"insert into invites (token,room_id,created_by,role_id,max_uses) values ('cfo1','{R5}','{G}','r1',1),('dir1','{R5}','{G}','r2',null)", anonymous=True), "INSERT 0 2")
check("join page shows the role and its ask", anon("select role_title, role_ask, usable, is_full from invite_preview('cfo1')"), "CFO | Add the cost numbers. | True | False")
check("joining with a role link", as_user(B, "select join_room('cfo1')"), R5)
check("roster shows the role title", as_user(G, f"select role_title, rapid_role from room_roster('{R5}') where user_id='{B}'", anonymous=True), "CFO | approver")
check("a full role link turns people away", as_user(C, "select join_room('cfo1')"), "role_full")
check("join page says the role is full", anon("select usable, is_full from invite_preview('cfo1')"), "False | True")
check("open-ended role link takes anyone", as_user(C, "select join_room('dir1')"), R5)
check("members can't retitle themselves", as_user(C, f"update memberships set role_title='CEO' where room_id='{R5}' and user_id='{C}'"), "only_owner_changes_roles")
check("member answers the role ask privately", as_user(B, f"""insert into inputs (room_id,user_id,weights,risk_appetite,gut_pick,role_answer,role_files) values ('{R5}','{B}','{good}','safe','a','Costs are 4M.','[{{"name":"budget.csv","text":"a,b"}}]')"""), "INSERT 0 1")
check("others can't read that answer", as_user(C, f"select count(*) from inputs where room_id='{R5}' and user_id='{B}'"), "\n0\n")
check("server can count role drafts", server(f"select use_quota('{G}','roles',5)"), "True")

# ---------- Decide jobs (20261021000000_decide_jobs.sql) ----------
check("people can't claim analysis jobs", as_user(G, "select * from claim_decide_job()", anonymous=True), "permission denied")
server(f"update rooms set status='deciding', decide_requested_at=now(), decide_started_at=null, decide_attempts=0 where id='{R5}'")
check("server claims a waiting room", server("select id, decide_attempts from claim_decide_job()"), f"{R5} | 1")
check("a running job isn't claimed twice", server("select count(*) from claim_decide_job()"), "\n0\n")
check("a job that went quiet is picked up again", server("select decide_attempts from claim_decide_job('0 seconds')"), "\n2\n")
check("after too many tries nothing is claimed", server("select count(*) from claim_decide_job('0 seconds')"), "\n0\n")
check("and the room reopens for the owner", server(f"select status, decide_error from rooms where id='{R5}'"), "open | upstream")
server(f"update rooms set status='deciding', decide_requested_at=now() - interval '1 minute', decide_started_at=null, decide_attempts=0, decide_error=null where id='{R5}'")
server(f"insert into analyses (room_id) values ('{R5}')")
check("a finished job isn't claimed", server("select count(*) from claim_decide_job('0 seconds')"), "\n0\n")

# ---------- Governance (20261022000000_governance.sql) ----------
O3, O4, O5 = (str(uuid.uuid4()) for _ in range(3))
check("approver can object after the call is drafted", as_user(B, f"insert into objections (id,room_id,user_id,reason) values ('{O3}','{R5}','{B}','Costs are understated')"), "INSERT 0 1")
server(f"update analyses set verdict='{{\"call\":\"a\"}}' where room_id='{R5}'")
check("an open objection blocks settling the call", as_user(G, f"select decide_verdict('{R5}','accepted')", anonymous=True), "objection_open")
server(f"update rooms set override_rule='approver' where id='{R5}'")
check("when only the approver can withdraw, the owner can't override", as_user(G, f"select override_objection('{O3}','We go ahead')", anonymous=True), "only_approver_withdraws")
check("authority rule needs a role", server(f"update rooms set override_rule='authority', override_role_id=null where id='{R5}'"), "rooms_authority_needs_role")
server(f"update rooms set override_rule='authority', override_role_id='r2' where id='{R5}'")
check("owner below the authority can't override", as_user(G, f"select override_objection('{O3}','We go ahead')", anonymous=True), "only_authority_overrides")
check("the named authority overrides on the record", (as_user(C, f"select override_objection('{O3}','Board approved the budget')") + as_user(C, f"select status, override_reason from objections where id='{O3}'")), "overridden | Board approved the budget")
check("objection to one option", as_user(B, f"insert into objections (id,room_id,user_id,reason,option_id) values ('{O4}','{R5}','{B}','Not option B','b')"), "INSERT 0 1")
check("it doesn't block a call for another option", as_user(G, f"select decide_verdict('{R5}','accepted')", anonymous=True), "SELECT 1")
rep2 = as_user(C, f"select report_for_member('{R5}')")
check("report carries the decision record", rep2, "'override_rule': 'authority'")
check("record names the objector by role, not name", ("'by_role': 'CFO'" in rep2 and "'B'" not in rep2) and "ok" or rep2, "ok")
check("record keeps the override reason", rep2, "Board approved the budget")

# ---------- Follow-up plan (20261023000000_followup.sql) ----------
P1 = str(uuid.uuid4())
check("owner adds a plan item for a member", as_user(G, f"insert into plan_items (id,room_id,title,assignee,due_date,created_by) values ('{P1}','{R5}','Sign the Lisbon lease','{B}','2026-11-30','{G}')", anonymous=True), "INSERT 0 1")
check("members see the plan", as_user(C, f"select title from plan_items where room_id='{R5}'"), "Sign the Lisbon lease")
check("members can't add to the plan", as_user(C, f"insert into plan_items (room_id,title,created_by) values ('{R5}','x','{C}')"), "row-level security")
check("plan items go to people in the room", as_user(G, f"insert into plan_items (room_id,title,assignee,created_by) values ('{R5}','x','{D}','{G}')", anonymous=True), "row-level security")
check("assignee moves their item along", as_user(B, f"update plan_items set status='doing', note='Draft sent' where id='{P1}'"), "UPDATE 1")
check("assignee can't rewrite the item", as_user(B, f"update plan_items set title='Something else' where id='{P1}'"), "only_owner_edits_plan")
check("others can't touch someone's item", as_user(C, f"update plan_items set status='done' where id='{P1}'"), "UPDATE 0")
check("report carries the plan", as_user(C, f"select report_for_member('{R5}')"), "Sign the Lisbon lease")
check("report mode defaults to both", as_user(C, f"select report_mode from rooms where id='{R5}'"), "both")
check("server counts the new helpers", server(f"select use_quota('{G}','helper',5)"), "True")

# ---------- Release 1 (20261025000000_release1.sql) ----------
R6 = str(uuid.uuid4())
check("room with a decide-by date", as_user(G, f"insert into rooms (id,workspace_id,type,question,options,criteria,owner_id,decide_by) values ('{R6}','{G}','business','Hire a CTO?','{opts}','{crit}','{G}','2026-11-01')", anonymous=True), "INSERT 0 1")
check("owner makes a personal invite", as_user(G, f"insert into invites (token,room_id,created_by,person_name,person_contact,max_uses) values ('kenji1','{R6}','{G}','Kenji','kenji@x.test',1)", anonymous=True), "INSERT 0 1")
check("a personal invite is single use", as_user(G, f"insert into invites (token,room_id,created_by,person_name,max_uses) values ('kenji2','{R6}','{G}','Kenji',null)", anonymous=True), "invites_personal_once")
check("join page greets the person with their contact", anon("select person_name, person_contact, usable from invite_preview('kenji1')"), "Kenji | kenji@x.test | True")
check("Kenji joins", as_user(E, "select join_room('kenji1')"), R6)
check("owner sees who joined", as_user(G, f"select joined_by from invites where token='kenji1'", anonymous=True), E)
check("contact is hidden once the link is used", anon("select person_name, person_contact is null from invite_preview('kenji1')"), "Kenji | True")
check("a used personal link turns others away", as_user(C, "select join_room('kenji1')"), "invite_used")
check("members can't read invites", as_user(E, f"select count(*) from invites where room_id='{R6}'"), "\n0\n")
check("owner saves a contact", as_user(G, "insert into contacts (name,contact,role_title) values ('Kenji','kenji@x.test','CFO')", anonymous=True), "INSERT 0 1")
check("contacts are private to their owner", as_user(E, "select count(*) from contacts"), "\n0\n")
check("can't save a contact for someone else", as_user(E, f"insert into contacts (owner_id,name) values ('{G}','X')"), "row-level security")
check("member comments on a rating", as_user(E, f"""insert into inputs (room_id,user_id,weights,risk_appetite,gut_pick,comments) values ('{R6}','{E}','{good}','safe','a','{{"cash":"We have 4 months of runway"}}')"""), "INSERT 0 1")
check("comments stay private", as_user(G, f"select count(*) from inputs where room_id='{R6}'", anonymous=True), "\n0\n")
check("comments must be an object", as_user(E, f"update inputs set comments='[1]' where room_id='{R6}' and user_id='{E}'"), "check constraint")
check("Your rooms lists decide-by and invites", as_user(G, f"select decide_by, invited, submitted from my_rooms() where id='{R6}'", anonymous=True), "2026-11-01 | 1 | 1")
check("members don't see invite counts", as_user(E, f"select invited is null from my_rooms() where id='{R6}'"), "True")
check("Your rooms names the final call", as_user(C, f"select final_label from my_rooms() where id='{R5}'"), "Open now")

# ---------- Room status is managed (20261026000000_room_guard.sql) ----------
R10 = str(uuid.uuid4())
check("can't open a room already deciding", as_user(G, f"insert into rooms (id,workspace_id,type,question,options,criteria,owner_id,status,decide_requested_at) values ('{R10}','{G}','business','Q?','{opts}','{crit}','{G}','deciding',now())", anonymous=True), "room_status_is_managed")
check("owner can't start a run by hand", as_user(G, f"update rooms set status='deciding', decide_requested_at=now(), decide_attempts=0 where id='{R6}'", anonymous=True), "room_status_is_managed")
check("owner can't reopen a decided room by hand", as_user(G, f"update rooms set status='open' where id='{R5}'", anonymous=True), "room_status_is_managed")
check("owner can't mark a room reviewed by hand", as_user(G, f"update rooms set status='reviewed' where id='{R6}'", anonymous=True), "room_status_is_managed")
check("owner can't change the decide columns by hand", as_user(G, f"update rooms set decide_error='x', decide_attempts=0 where id='{R6}'", anonymous=True), "room_status_is_managed")
check("owner still edits review date and report", as_user(G, f"update rooms set review_date='2027-01-15', report_mode='team', links='[]' where id='{R5}'", anonymous=True), "UPDATE 1")
check("server still moves status", server(f"update rooms set status='deciding', decide_requested_at=now() where id='{R6}'"), "UPDATE 1")
check("server still claims the job", server("select id from claim_decide_job()"), R6)

# ---------- Review (20261027000000_review.sql) ----------
check("outcomes can't be written directly", as_user(G, f"insert into outcomes (room_id,what_happened,rating,logged_by) values ('{R5}','x',4,'{G}')", anonymous=True), "row-level security")
check("a settled room has review 1 open", as_user(C, f"select review_state('{R5}')->>'round'"), "\n1\n")
check("member rates privately", as_user(B, f"insert into review_ratings (room_id,user_id,review_no,rating,note) values ('{R5}','{B}',1,4,'Costs came in on budget')"), "INSERT 0 1")
check("can't rate a review that isn't open", as_user(C, f"insert into review_ratings (room_id,user_id,review_no,rating) values ('{R5}','{C}',2,2)"), "row-level security")
check("others can't read a rating", as_user(C, f"select count(*) from review_ratings where room_id='{R5}'"), "\n0\n")
check("owner can't read a rating either", as_user(G, f"select count(*) from review_ratings where room_id='{R5}'", anonymous=True), "\n0\n")
check("only the owner logs the review", as_user(B, f"select log_review('{R5}','Fine',4)"), "only_owner_reviews")
check("next review must be in the future", as_user(G, f"select log_review('{R5}','Fine',4,'',date '2020-01-01')", anonymous=True), "next_review_in_future")
check("owner logs review 1", as_user(G, f"select log_review('{R5}','Opened on time, costs on budget',4,'Lock rent early')", anonymous=True), "\n1\n")
check("room is reviewed", server(f"select status from rooms where id='{R5}'"), "reviewed")
check("an early review leaves nothing open", as_user(C, f"select review_state('{R5}')->>'round' is null"), "True")
check("small room: average only, no spread or notes", as_user(C, f"select s->>'avg', s->>'min', jsonb_array_length(s->'notes') from jsonb_array_elements(review_summary('{R5}')) s"), "4.0 | None | 0")
check("outsiders see no summary", as_user(E, f"select review_summary('{R5}')"), "[]")
check("an open room has no review", as_user(G, f"select log_review('{R6}','x',3)", anonymous=True), "no_review_open")
check("report carries the review", as_user(C, f"select report_for_member('{R5}')"), "Opened on time")

# ---------- Accounts and profiles (20261028000000_accounts.sql) ----------
check("member fills in the profile", as_user(B, "update profiles set organisation='Tejarra', job_title='CFO', country='AE' where id=(select auth.uid())"), "UPDATE 1")
check("profile is complete once the required fields are in", as_user(B, "select completed_at is not null from profiles where id=(select auth.uid())"), "True")
check("a verified email can't be changed from the profile", (as_user(B, "update profiles set email='fake@x.test' where id=(select auth.uid())") + as_user(B, "select email from profiles where id=(select auth.uid())")), "B@x.test")
check("country must be a two-letter code", as_user(B, "update profiles set country='United Arab Emirates' where id=(select auth.uid())"), "check constraint")
check("can't edit someone else's profile", as_user(C, f"update profiles set organisation='X' where id='{B}'"), "UPDATE 0")
check("email change at sign-in reaches the profile", (server(f"update auth.users set email='b2@x.test' where id='{B}'") + server(f"select email from profiles where id='{B}'")), "b2@x.test")
check("Google's full name is used for new accounts", (server("insert into auth.users (id,email,raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000aa','g@x.test','{\"full_name\":\"Kenji Watanabe\"}')") + server("select name from profiles where id='00000000-0000-0000-0000-0000000000aa'")), "Kenji Watanabe")

# ---------- Admin page (20261029000000_admin.sql) ----------
check("people can't open the admin overview", as_user(B, "select admin_overview()"), "permission denied")
check("people can't read the operator list", as_user(B, "select count(*) from operators"), "\n0\n")
check("people can't add themselves as operator", as_user(B, f"insert into operators (user_id) values ('{B}')"), "row-level security")
check("people can't read AI costs", as_user(B, "select count(*) from ai_usage"), "\n0\n")
check("server records an AI call", server(f"insert into ai_usage (kind,room_id,user_id,model,tokens_in,tokens_out,searches,cost) values ('analyst','{R5}','{G}','gpt-5.5',20000,6000,3,0.29)"), "INSERT 0 1")
check("server builds the overview", server("select admin_overview()->>'accounts', admin_overview()->'cost_by_kind'->>'analyst'"), "0.29")

# ---------- Organisations (20261030000000_organisations.sql) ----------
OW = str(uuid.uuid4())
check("people can't create an organisation", as_user(B, f"insert into workspaces (id,name,owner_id,kind) values ('{OW}','Acme','{B}','organisation')"), "row-level security")
server(f"insert into workspaces (id,name,owner_id,kind,org_type,email_domain) values ('{OW}','Ministry of Tests','{A}','organisation','government','x.test')")
server(f"delete from workspace_members where workspace_id='{OW}'")   # the operator who made it isn't a member
server(f"insert into org_invites (workspace_id,email,name,role) values ('{OW}','C@x.test','C','admin'),('{OW}','D@x.test','D','member')")
check("an invited admin joins on sign-in", as_user(C, "select claim_org_invites()"), "\n1\n")
check("they are the organisation's admin", as_user(C, f"select role from my_orgs() where id='{OW}'"), "admin")
check("admin adds a department", as_user(C, f"insert into departments (workspace_id,name) values ('{OW}','Finance')"), "INSERT 0 1")
check("admin invites someone by email", as_user(C, f"insert into org_invites (workspace_id,email,invited_by) values ('{OW}','E@x.test','{C}')"), "INSERT 0 1")
check("admin can't invite an owner", as_user(C, f"insert into org_invites (workspace_id,email,invited_by,role) values ('{OW}','zz@x.test','{C}','owner')"), "row-level security")
check("admin renames the organisation and opens the join link", as_user(C, f"update workspaces set name='Ministry of Testing', join_open=true where id='{OW}'"), "UPDATE 1")
check("admin can't verify their own domain", as_user(C, f"update workspaces set domain_verified=true where id='{OW}'"), "operator_only")
check("a member can't invite", as_user(D, f"insert into org_invites (workspace_id,email,invited_by) values ('{OW}','q@x.test','{D}')") if False else as_user(B, f"insert into org_invites (workspace_id,email,invited_by) values ('{OW}','q@x.test','{B}')"), "row-level security")
tok = server(f"select join_token from workspaces where id='{OW}'").strip().split("\n")[-1]
check("join page shows the organisation", anon(f"select name, usable from org_preview('{tok}')"), "Ministry of Testing | True")
check("joining with the private link", as_user(B, f"select join_org('{tok}')"), OW)
check("members see the directory", as_user(B, f"select count(*) from org_directory('{OW}')"), "\n2\n")
check("outsiders see no directory", as_user(E, f"select count(*) from org_directory('{OW}')"), "\n0\n")
check("a member opens a room in the organisation", as_user(B, f"insert into rooms (id,workspace_id,type,question,options,criteria,owner_id) values ('{str(uuid.uuid4())}','{OW}','business','Merge two units?','{opts}','{crit}','{B}')"), "INSERT 0 1")
check("admin sees the room list", as_user(C, f"select question from org_rooms('{OW}')"), "Merge two units?")
check("members don't see the room list", as_user(B, f"select count(*) from org_rooms('{OW}')"), "\n0\n")
check("admin still can't read answers", as_user(C, f"select count(*) from inputs i join rooms r on r.id=i.room_id where r.workspace_id='{OW}'"), "\n0\n")
server(f"update workspaces set domain_verified=true where id='{OW}'")
check("an invite and a matching domain join only once", as_user(E, "select claim_org_invites()"), "\n1\n")
server(f"update workspace_members set role='member' where workspace_id='{OW}'")
server(f"delete from workspace_members where workspace_id='{OW}' and user_id='{D}'")
server(f"delete from org_invites where workspace_id='{OW}' and email='D@x.test'")
check("a verified domain lets colleagues join on sign-in", as_user(D, "select claim_org_invites()"), "\n1\n")
server(f"update workspace_members set role='admin' where workspace_id='{OW}' and user_id='{C}'")
check("member leaves the organisation", as_user(B, f"delete from workspace_members where workspace_id='{OW}' and user_id='{B}'"), "DELETE 1")
check("operator sees the organisations", server("select jsonb_array_length(admin_orgs())"), "\n1\n")

# ---------- Growth dashboard (20261031000000_growth.sql) ----------
check("people can't open the growth numbers", as_user(B, "select admin_growth()"), "permission denied")
g = server("select admin_growth()")
check("growth numbers build", g, "north" if False else "'weeks'")
check("12 weeks of history", server("select jsonb_array_length(admin_growth()->'weeks')"), "\n12\n")
check("room funnel counts rooms", server("select (admin_growth()->'rooms'->>'opened')::int > 0"), "True")
check("people can't read admin requests", as_user(B, "select * from operator_requests"), "permission denied")
check("people can't approve themselves", as_user(B, f"insert into operator_requests (user_id, status) values ('{B}', 'approved')"), "permission denied")
check("sign-up source is saved once", (as_user(B, "update profiles set signup_source='room_invite' where id=(select auth.uid())") + as_user(B, "update profiles set signup_source='direct' where id=(select auth.uid())") + as_user(B, "select signup_source from profiles where id=(select auth.uid())")), "room_invite")

# ---------- Revenue (20261101000000_revenue.sql) ----------
check("people can't read revenue", as_user(B, "select * from revenue_subscriptions"), "permission denied")
check("people can't add invoices", as_user(B, "insert into revenue_invoices (customer_name, kind, amount) values ('x', 'other', 1)"), "permission denied")
check("people can't open the revenue numbers", as_user(B, "select admin_revenue()"), "permission denied")
# A moved from Small to Team at the start of last month; C pays yearly; an offline client left this month.
server(f"""insert into revenue_subscriptions (user_id, customer_name, plan, amount, started_on, ended_on) values
  ('{A}', 'A', 'small', 39, date_trunc('month', current_date) - interval '3 months', date_trunc('month', current_date) - interval '1 month'),
  ('{A}', 'A', 'team', 99, date_trunc('month', current_date) - interval '1 month', null);
  insert into revenue_subscriptions (user_id, customer_name, plan, amount, period, started_on, renews_on) values
  ('{C}', 'C', 'organisation', 1200, 'year', date_trunc('month', current_date) - interval '2 months', current_date + 10);
  insert into revenue_subscriptions (customer_name, plan, amount, started_on, ended_on, end_reason) values
  ('Offline Co', 'small', 39, date_trunc('month', current_date) - interval '5 months', date_trunc('month', current_date), 'Budget');
  insert into revenue_invoices (user_id, customer_name, kind, amount, issued_on, due_on) values ('{A}', 'A', 'subscription', 99, current_date - 30, current_date - 16);
  insert into revenue_invoices (customer_name, kind, amount, issued_on, due_on, paid_on) values ('Gov', 'facilitated', 1500, current_date - 20, current_date - 6, current_date - 3);""")
check("MRR counts monthly and yearly plans", server("select admin_revenue()->'now'->>'mrr'"), "\n199.00\n")
check("ARR is 12 times MRR", server("select admin_revenue()->'now'->>'arr'"), "\n2388.00\n")
check("plan change shows as expansion", server("select (select m->>'expansion' from jsonb_array_elements(admin_revenue()->'months') m where (m->>'month')::date = (date_trunc('month', current_date) - interval '1 month')::date)"), "\n60.00\n")
check("offline client counts as lost", server("select (admin_revenue()->'months'->11->>'churned')"), "\n39.00\n")
check("overdue invoice listed", server("select admin_revenue()->>'overdue'"), "\n99.00\n")
check("renewal within 30 days listed", server("select jsonb_array_length(admin_revenue()->'renewals')"), "\n1\n")
check("one-off revenue by kind", server("select admin_revenue()->'one_off'->0->>'kind'"), "facilitated")
check("churned customer listed with reason", server("select admin_revenue()->'churned'->0->>'reason'"), "Budget")
check("paid and void can't both be true", server("insert into revenue_invoices (customer_name, kind, amount, paid_on, void) values ('x', 'other', 1, current_date, true)"), "violates check")

# ---------- Nudges (20261102000000_nudges.sql) ----------
RN = str(uuid.uuid4()); TN = "nudgetoken" + "x" * 30
check("nudge room opens", as_user(A, f"insert into rooms (id,workspace_id,type,question,options,criteria,owner_id,decide_by) values ('{RN}','{W}','business','Nudge me?','{opts}','{crit}','{A}', current_date + 2)"), "INSERT 0 1")
server(f"insert into invites (token, room_id, created_by, person_name, person_contact, max_uses, created_at) values ('{TN}', '{RN}', '{A}', 'Kenji', 'kenji@x.test', 1, now() - interval '3 days')")
server(f"insert into memberships (room_id, user_id, role, joined_at) values ('{RN}', '{D}', 'member', now() - interval '10 days')")
due = server("select kind, coalesce(invite_token, user_id::text), email from nudge_due() where question = 'Nudge me?' order by email")
check("halfway reminder due for an unopened invite", due, "half | " + TN + " | kenji@x.test")
check("halfway reminder due for a member who hasn't answered", due, "half | " + D)
check("people can't list due reminders", as_user(B, "select * from nudge_due()"), "permission denied")
check("opening an invite is recorded", as_user(B, f"select invite_opened('{TN}')") + server(f"select opened_at is not null from invites where token='{TN}'"), "True")
server(f"insert into nudges (room_id, invite_token, kind) values ('{RN}', '{TN}', 'half')")
check("a reminder goes only once", server(f"select count(*) from nudge_due() where invite_token = '{TN}'"), "\n0\n")
check("owner sees how often someone was reminded", as_user(A, f"select n from room_nudges('{RN}') where invite_token = '{TN}'"), "\n1\n")
check("members don't see reminders", as_user(D, f"select count(*) from room_nudges('{RN}')"), "\n0\n")
check("people can't read the reminder log", as_user(A, "select * from nudges"), "permission denied")
check("owner switches reminders off", as_user(A, f"update rooms set auto_nudge = false where id = '{RN}'"), "UPDATE 1")
check("no reminders once switched off", server("select count(*) from nudge_due() where question = 'Nudge me?'"), "\n0\n")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
