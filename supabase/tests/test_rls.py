# Privacy and validation checks for the Decision Rooms schema, on a throwaway embedded Postgres.
#   python3 -m venv .venv && .venv/bin/pip install pgserver "psycopg[binary]"
#   .venv/bin/python supabase/tests/test_rls.py supabase/migrations/20261012000000_decision_rooms.sql
"""Run the Decision Rooms migration on embedded Postgres with Supabase stubs, then test RLS."""
import sys, tempfile, uuid, pgserver, psycopg

MIGRATION = sys.argv[1]
STUB = """
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth; create schema storage;
create table auth.users (id uuid primary key, email text, phone text, raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
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
    db(open(MIGRATION).read())
except Exception as e:
    print("MIGRATION ERROR:", e); sys.exit(1)
print("migration applied")

A, B, C, D, E = (str(uuid.uuid4()) for _ in range(5))
db("".join(f"insert into auth.users (id,email,raw_user_meta_data) values ('{u}','{n}@x.test','{{\"name\":\"{n}\"}}');"
           for u, n in zip((A, B, C, D, E), "ABCDE")))

def as_user(u, sql):
    """Run one statement as user u. Returns 'STATUS', rows as 'a | b' lines, or 'ERROR: ...'."""
    try:
        with conn.transaction(), conn.cursor() as cur:
            cur.execute("set local role authenticated")
            cur.execute("select set_config('request.jwt.claim.sub', %s, true)", (u,))
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
check("override needs a reason", as_user(A, f"select decide_verdict('{R}','overridden','  ')"), "check constraint")
check("owner overrides with reason", as_user(A, f"select decide_verdict('{R}','overridden','Cash first this year')"), "SELECT 1")
check("inputs locked once decided", as_user(B, f"update inputs set concern='late' where room_id='{R}' and user_id='{B}'"), "room_not_open")

check("signoff then counts", (as_user(C, f"insert into signoffs (room_id,user_id,stance) values ('{R}','{C}','object')") + as_user(C, f"select stance, n from signoff_counts('{R}')")), "object | 1")
check("others can't read who objected", as_user(A, f"select count(*) from signoffs where room_id='{R}'"), "\n0\n")

check("storage: member reads room file", as_user(B, f"select count(*) from storage.objects where bucket_id='room-files' and name like '{R}/%'"), "SELECT 1")
check("storage: member can't upload", as_user(B, f"insert into storage.objects (bucket_id,name) values ('room-files','{R}/x.pdf')"), "row-level security")
check("storage: owner uploads", as_user(A, f"insert into storage.objects (bucket_id,name) values ('room-files','{R}/x.pdf')"), "INSERT 0 1")
check("storage: junk path is denied, not an error", as_user(A, "insert into storage.objects (bucket_id,name) values ('room-files','nope/x.pdf')"), "row-level security")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
