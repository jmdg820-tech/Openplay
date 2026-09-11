import pg from "pg";

const { Client } = pg;

const CONN_BASE = {
  host: "localhost",
  port: 5433,
  database: "openplay_test",
};

// Connects as the real Postgres superuser -- used only for building test
// fixtures directly (inserting rows that would normally arrive via
// auth.users signups, seeding venues/sessions, inspecting raw state to
// verify outcomes) and for the service_role-equivalent checks that need
// BYPASSRLS. Not used for anything we're asserting access CONTROL on.
export async function superuserClient() {
  const c = new Client({ ...CONN_BASE, user: "postgres", password: "postgres" });
  await c.connect();
  return c;
}

// Opens a connection as one of the three Supabase-style roles and, for
// authenticated/service, sets request.jwt.claims so auth.uid() resolves
// exactly the way it would behind real PostgREST.
export async function asRole(role, userId) {
  const userMap = {
    anon: { user: "test_anon", password: "test" },
    authenticated: { user: "test_authenticated", password: "test" },
    service: { user: "test_service", password: "test" },
  };
  const creds = userMap[role];
  if (!creds) throw new Error(`unknown role ${role}`);
  const c = new Client({ ...CONN_BASE, ...creds });
  await c.connect();
  if (role === "authenticated" && userId) {
    await c.query("select set_config('request.jwt.claims', $1, false)", [
      JSON.stringify({ sub: userId }),
    ]);
  }
  if (role === "service") {
    // Role ATTRIBUTES (BYPASSRLS among them) are never inherited through
    // role membership in Postgres -- only privileges (GRANTs) are. Real
    // PostgREST doesn't log in directly as service_role either: its
    // `authenticator` role issues `SET ROLE service_role` per-request based
    // on the JWT, which does make BYPASSRLS apply (SET ROLE assumes the
    // target role's own attributes). Mirror that here rather than relying
    // on test_service's inherited grants, which would silently be RLS-
    // filtered on any FORCE-RLS table with zero policies (e.g.
    // session_participants) even though real service_role access wouldn't be.
    await c.query("set role service_role");
  }
  return c;
}

export async function createUser(su, { name = "Test Player", isAdmin = false } = {}) {
  const { rows } = await su.query(
    `insert into auth.users (raw_user_meta_data) values ($1) returning id`,
    [JSON.stringify({ name })]
  );
  const id = rows[0].id;
  if (isAdmin) {
    await su.query(`update profiles set is_platform_admin = true where id = $1`, [id]);
  }
  return id;
}

export async function createVenue(su, creatorId, { numberOfCourts = 4 } = {}) {
  const { rows } = await su.query(
    `insert into venues (name, location, number_of_courts, created_by)
     values ('Test Venue', point(121.05, 14.55), $1, $2)
     returning id`,
    [numberOfCourts, creatorId]
  );
  return rows[0].id;
}

export async function createSession(
  su,
  organizerId,
  venueId,
  { sessionType = "doubles", capacity = 4, startOffsetMin = 60, durationMin = 90 } = {}
) {
  const { rows } = await su.query(
    `insert into sessions (venue_id, created_by, session_type, start_time, end_time, capacity)
     values ($1, $2, $3, now() + ($4 || ' minutes')::interval, now() + ($5 || ' minutes')::interval, $6)
     returning id`,
    [venueId, organizerId, sessionType, startOffsetMin, startOffsetMin + durationMin, capacity]
  );
  return rows[0].id;
}

export async function truncateAll(su) {
  await su.query(`
    truncate table
      blocks, reports, notification_outbox, push_tokens, guest_contacts,
      session_participants, sessions, venue_staff, venues, profiles, auth.users
    cascade
  `);
}
