# Privacy and validation checks for the Decision Rooms schema, on a throwaway embedded Postgres.
#   python3 -m venv .venv && .venv/bin/pip install pgserver "psycopg[binary]"
#   .venv/bin/python supabase/tests/test_rls.py supabase/migrations/*.sql
"""Run the Decision Rooms migration on embedded Postgres with Supabase stubs, then test RLS."""
import sys, tempfile, uuid, pgserver, psycopg

MIGRATIONS = sorted(sys.argv[1:])
STUB = """
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth; create schema storage;
create table auth.users (id uuid primary key, email text, phone text, raw_user_meta_data jsonb default '{}');
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
check("override needs a reason", as_user(G, f"select override_objection('{O}','  ')", anonymous=True), "check constraint")
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

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
