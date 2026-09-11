import assert from "node:assert/strict";
import {
  superuserClient,
  asRole,
  createUser,
  createVenue,
  createSession,
  truncateAll,
} from "./lib/db.mjs";

const results = [];

async function t(category, name, fn) {
  try {
    const detail = await fn();
    results.push({ category, name, status: "PASS", detail: detail || "" });
  } catch (err) {
    results.push({ category, name, status: "FAIL", detail: err.message });
  }
}

function blocked(category, name, reason) {
  results.push({ category, name, status: "BLOCKED", detail: reason });
}

async function withClients(fn) {
  const clients = [];
  const open = async (role, userId) => {
    const c = await asRole(role, userId);
    clients.push(c);
    return c;
  };
  try {
    await fn(open);
  } finally {
    for (const c of clients) await c.end().catch(() => {});
  }
}

async function main() {
  const su = await superuserClient();
  await truncateAll(su);

  // ---------------------------------------------------------------------
  // Common fixtures reused across sections
  // ---------------------------------------------------------------------
  const organizerId = await createUser(su, { name: "Organizer O" });
  const staffUserId = await createUser(su, { name: "Staff D" });
  const playerBId = await createUser(su, { name: "Player B" });
  const nonMemberId = await createUser(su, { name: "Non Member C" });
  const adminId = await createUser(su, { isAdmin: true, name: "Admin X" });

  await su.query(`update profiles set skill_level = 'advanced' where id = $1`, [playerBId]);

  const venueId = await createVenue(su, organizerId, { numberOfCourts: 4 });
  const sessionId = await createSession(su, organizerId, venueId, {
    sessionType: "doubles",
    capacity: 4,
  });

  // playerB joins as a confirmed participant
  let playerBParticipantId;
  await withClients(async (open) => {
    const c = await open("authenticated", playerBId);
    const r = await c.query(
      `select * from join_session($1, null, null, null)`,
      [sessionId]
    );
    playerBParticipantId = r.rows[0].participant_id;
    assert.equal(r.rows[0].status, "confirmed");
  });

  // Attach staffUser as staff of the main venue directly via superuser
  // (bypasses RLS, as a fixture-setup shortcut) to exercise the
  // organizer/venue-staff-of-THIS-venue visibility path cleanly.
  await su.query(`insert into venue_staff (venue_id, user_id) values ($1, $2)`, [
    venueId,
    staffUserId,
  ]);

  // =======================================================================
  // SECTION 1 — PRIVACY TESTS (profiles / roster visibility matrix)
  // =======================================================================

  await t("privacy", "anon: get_session_roster skill_level is NULL", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      const r = await c.query(`select * from get_session_roster($1)`, [sessionId]);
      const row = r.rows.find((x) => x.participant_id === playerBParticipantId);
      assert.ok(row, "row must be present");
      assert.equal(row.skill_level, null);
      assert.equal(row.display_name, "Player B");
    });
  });

  await t("privacy", "authenticated non-member: skill_level is NULL", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      const r = await c.query(`select * from get_session_roster($1)`, [sessionId]);
      const row = r.rows.find((x) => x.participant_id === playerBParticipantId);
      assert.equal(row.skill_level, null);
    });
  });

  await t("privacy", "joined participant: skill_level visible to self and peers", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", playerBId);
      const r = await c.query(`select * from get_session_roster($1)`, [sessionId]);
      const row = r.rows.find((x) => x.participant_id === playerBParticipantId);
      assert.equal(row.skill_level, "advanced");
    });
  });

  await t("privacy", "organizer: skill_level visible", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", organizerId);
      const r = await c.query(`select * from get_session_roster($1)`, [sessionId]);
      const row = r.rows.find((x) => x.participant_id === playerBParticipantId);
      assert.equal(row.skill_level, "advanced");
      assert.equal(row.is_guest, false);
    });
  });

  await t("privacy", "venue staff: skill_level visible", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", staffUserId);
      const r = await c.query(`select * from get_session_roster($1)`, [sessionId]);
      const row = r.rows.find((x) => x.participant_id === playerBParticipantId);
      assert.equal(row.skill_level, "advanced");
    });
  });

  await t("privacy", "skill visibility is per-session, not global", async () => {
    // playerB has NOT joined this second session; a different player there
    // should show NULL skill_level to playerB.
    const session2 = await createSession(su, organizerId, venueId, { capacity: 4 });
    const playerEId = await createUser(su, { name: "Player E" });
    await su.query(`update profiles set skill_level = 'beginner' where id = $1`, [playerEId]);
    await withClients(async (open) => {
      const eClient = await open("authenticated", playerEId);
      await eClient.query(`select * from join_session($1, null, null, null)`, [session2]);

      const bClient = await open("authenticated", playerBId);
      const r = await bClient.query(`select * from get_session_roster($1)`, [session2]);
      const row = r.rows.find((x) => x.display_name === "Player E");
      assert.equal(row.skill_level, null, "playerB has not joined session2, must not see skill");
    });
  });

  await t("privacy", "profiles raw table: self-only, is_platform_admin never exposed to others", async () => {
    await withClients(async (open) => {
      const asAdmin = await open("authenticated", adminId);
      const own = await asAdmin.query(`select * from profiles where id = $1`, [adminId]);
      assert.equal(own.rows.length, 1);
      assert.equal(own.rows[0].is_platform_admin, true);

      const asOther = await open("authenticated", playerBId);
      const others = await asOther.query(`select * from profiles where id = $1`, [adminId]);
      assert.equal(others.rows.length, 0, "non-owner must see zero rows for another profile");

      const anonC = await open("anon");
      await assert.rejects(
        anonC.query(`select * from profiles where id = $1`, [adminId]),
        /permission denied/i,
        "anon has no grant at all on the raw profiles table"
      );
    });
  });

  await t("privacy", "public_profiles view exposes only id/name/photo_url (no skill_level column)", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      const r = await c.query(`select id, name, photo_url from public_profiles where id = $1`, [playerBId]);
      assert.equal(r.rows[0].name, "Player B");
      await assert.rejects(
        c.query(`select skill_level from public_profiles where id = $1`, [playerBId]),
        /column .*skill_level.* does not exist/i
      );
    });
  });

  await t("privacy", "affected user: reported/blocked user cannot see the report or block filed against them", async () => {
    await withClients(async (open) => {
      const reporterC = await open("authenticated", organizerId);
      await reporterC.query(`select submit_report($1, null, $2)`, [playerBId, "affected-user privacy case"]);
      // blocker_user_id is column-excluded from the authenticated INSERT
      // grant and force-set by the force_blocker_identity() trigger from
      // auth.uid() regardless of payload -- so this must run as an
      // authenticated connection with playerB's would-be blocker (organizerId)
      // as the JWT subject, not via the superuser client (whose auth.uid()
      // is NULL, which would violate the NOT NULL constraint instead of
      // proving the intended boundary).
      await reporterC.query(`insert into blocks (blocked_user_id) values ($1)`, [playerBId]);

      // playerB is the AFFECTED user (the one reported/blocked) -- reports_select_own
      // and blocks_select_own are both scoped to reporter_user_id/blocker_user_id,
      // never reported_user_id/blocked_user_id, so playerB must see zero rows.
      const affectedC = await open("authenticated", playerBId);
      const reportsSeen = await affectedC.query(`select * from reports where reported_user_id = $1`, [playerBId]);
      assert.equal(reportsSeen.rows.length, 0, "affected user must not see reports filed against them");
      const blocksSeen = await affectedC.query(`select * from blocks where blocked_user_id = $1`, [playerBId]);
      assert.equal(blocksSeen.rows.length, 0, "affected user must not see who blocked them");
    });
  });

  await t("privacy", "service role: bypasses RLS on raw session_participants and notification_outbox", async () => {
    await withClients(async (open) => {
      const serviceC = await open("service");
      const rows = await serviceC.query(`select * from session_participants where id = $1`, [playerBParticipantId]);
      assert.equal(rows.rows.length, 1, "service_role (BYPASSRLS) must see the raw row anon/authenticated cannot");
      assert.ok("management_token" in rows.rows[0], "raw column access confirms this is the real table, not a view");
      const outbox = await serviceC.query(`select count(*)::int as n from notification_outbox`);
      assert.ok(outbox.rows[0].n >= 0, "service_role can query notification_outbox directly (workers/schedulers)");
    });
  });

  await t("privacy", "session_participants is structurally absent from every Realtime publication", async () => {
    const pub = await su.query(
      `select 1 from pg_publication_tables where tablename = 'session_participants'`
    );
    assert.equal(pub.rows.length, 0, "session_participants must never be added to any publication");
    const sessionsPub = await su.query(
      `select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sessions'`
    );
    assert.equal(sessionsPub.rows.length, 1, "sessions IS expected in supabase_realtime per the approved spec");
  });

  // =======================================================================
  // SECTION 2 — ATTACK-PATH TESTS
  // =======================================================================

  await t("attack", "anonymous guesses participant_id (no token) -> rejected", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      await assert.rejects(
        c.query(`select leave_session($1, $2)`, [playerBParticipantId, "00000000-0000-0000-0000-000000000000"]),
        /not authorized/i
      );
    });
  });

  await t("attack", "anonymous guesses session_id -> yields only already-public info, no error", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      const r = await c.query(`select * from get_session_roster($1)`, ["11111111-1111-1111-1111-111111111111"]);
      assert.equal(r.rows.length, 0);
    });
  });

  let guestParticipantId, guestToken;
  await t("attack", "(setup) guest joins for token-guessing tests", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      const r = await c.query(
        `select * from join_session($1, $2, $3, $4)`,
        [sessionId, "Guest G", "email", "guest-g@example.com"]
      );
      guestParticipantId = r.rows[0].participant_id;
      guestToken = r.rows[0].management_token;
      assert.ok(guestToken);
    });
  });

  await t("attack", "anonymous guesses management_token (wrong token) -> rejected with generic error", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      await assert.rejects(
        c.query(`select leave_session($1, $2)`, [guestParticipantId, "99999999-9999-9999-9999-999999999999"]),
        (err) => {
          assert.match(err.message, /not authorized/i);
          assert.doesNotMatch(err.message, /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i, "error must not echo any token value");
          return true;
        }
      );
    });
  });

  await t("attack", "correct management_token -> leave succeeds", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      await c.query(`select leave_session($1, $2)`, [guestParticipantId, guestToken]);
      const check = await su.query(`select status from session_participants where id = $1`, [guestParticipantId]);
      assert.equal(check.rows[0].status, "left");
    });
  });

  await t("attack", "participant cannot raw-SELECT session_participants", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", playerBId);
      await assert.rejects(
        c.query(`select * from session_participants limit 1`),
        /permission denied/i
      );
    });
  });

  await t("attack", "participant cannot read guest_contacts for their own session (not organizer/staff)", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", playerBId);
      const r = await c.query(`select * from guest_contacts`);
      assert.equal(r.rows.length, 0, "grant exists but RLS must filter all rows for a non-qualifying viewer");
    });
  });

  await t("attack", "organizer CAN read guest_contacts for their own session", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", organizerId);
      const r = await c.query(
        `select * from guest_contacts where participant_id = $1`,
        [guestParticipantId]
      );
      assert.equal(r.rows.length, 1);
      assert.equal(r.rows[0].contact_value, "guest-g@example.com");
    });
  });

  await t("attack", "non-organizer cannot call cancel_session", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      await assert.rejects(
        c.query(`select cancel_session($1, $2)`, [sessionId, "not mine to cancel"]),
        /not authorized/i
      );
    });
  });

  await t("attack", "user cannot claim another user's venue", async () => {
    const otherVenueId = await createVenue(su, organizerId);
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      await assert.rejects(
        c.query(`select claim_venue($1)`, [otherVenueId]),
        /not authorized/i
      );
    });
  });

  await t("attack", "venue staff of venue A cannot read guest_contacts of venue B's sessions", async () => {
    const venueB = await createVenue(su, nonMemberId);
    const sessionB = await createSession(su, nonMemberId, venueB, { capacity: 4 });
    let guestBParticipant;
    await withClients(async (open) => {
      const anonC = await open("anon");
      const r = await anonC.query(`select * from join_session($1, $2, $3, $4)`, [
        sessionB, "Guest H", "email", "guest-h@example.com",
      ]);
      guestBParticipant = r.rows[0].participant_id;

      const staffA = await open("authenticated", staffUserId); // staff of venueId, not venueB
      const q = await staffA.query(
        `select gc.* from guest_contacts gc where gc.participant_id = $1`,
        [guestBParticipant]
      );
      assert.equal(q.rows.length, 0);
    });
  });

  await t("attack", "push token manipulation: cannot raw-UPDATE another user's token", async () => {
    await withClients(async (open) => {
      const ownerClient = await open("authenticated", playerBId);
      await ownerClient.query(`select register_push_token($1, $2)`, ["device-token-xyz", "android"]);

      const attacker = await open("authenticated", nonMemberId);
      await assert.rejects(
        attacker.query(`update push_tokens set user_id = $1 where token = $2`, [nonMemberId, "device-token-xyz"]),
        /permission denied/i
      );
    });
  });

  await t("attack", "caller-supplied user id cannot bypass authorization (raw INSERT into push_tokens for another user)", async () => {
    await withClients(async (open) => {
      const attacker = await open("authenticated", nonMemberId);
      await assert.rejects(
        attacker.query(
          `insert into push_tokens (user_id, token, platform) values ($1, $2, $3)`,
          [playerBId, "forged-token", "ios"]
        ),
        /permission denied/i
      );
    });
  });

  await t("attack", "is_platform_admin not exposed via public_profiles or roster", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      const pub = await c.query(`select * from public_profiles where id = $1`, [adminId]);
      assert.ok(!("is_platform_admin" in pub.rows[0]));

      await c.query(`select * from join_session($1, null, null, null)`, [sessionId]).catch(() => {});
      const roster = await c.query(`select * from get_session_roster($1)`, [sessionId]);
      for (const row of roster.rows) {
        assert.ok(!("is_platform_admin" in row));
      }
    });
  });

  blocked(
    "attack",
    "participant Realtime subscription to session_participants",
    "No Realtime service runs in this local Postgres-only harness (Supabase Realtime is a separate service, not present here). " +
    "Mitigation verified structurally instead: session_participants carries zero GRANTs to anon/authenticated (see the " +
    "'participant cannot raw-SELECT session_participants' PASS above), and the architecture deliberately excludes this " +
    "table from any Realtime publication -- there is nothing to subscribe to, for any role, by construction."
  );

  // =======================================================================
  // SECTION 3 — CONCURRENCY TESTS
  // =======================================================================

  await t("concurrency", "two simultaneous joins for the last slot -> exactly one confirmed, one waitlisted", async () => {
    const venue2 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue2, { sessionType: "singles", capacity: 2 });
    const p1 = await createUser(su, { name: "Racer 1" });

    await withClients(async (open) => {
      const c1 = await open("authenticated", p1);
      await c1.query(`select * from join_session($1, null, null, null)`, [s]); // fills 1 of 2 slots

      const racerA = await createUser(su, { name: "Racer A" });
      const racerB = await createUser(su, { name: "Racer B" });
      const cA = await open("authenticated", racerA);
      const cB = await open("authenticated", racerB);

      const [ra, rb] = await Promise.all([
        cA.query(`select * from join_session($1, null, null, null)`, [s]),
        cB.query(`select * from join_session($1, null, null, null)`, [s]),
      ]);

      const statuses = [ra.rows[0].status, rb.rows[0].status].sort();
      assert.deepEqual(statuses, ["confirmed", "waitlisted"]);

      const occCheck = await su.query(
        `select count(*) from session_participants where session_id = $1 and status in ('confirmed','pending_confirmation')`,
        [s]
      );
      assert.equal(Number(occCheck.rows[0].count), 2, "capacity must never be exceeded");
    });
  });

  await t("concurrency", "multiple simultaneous leaves -> correct number of promotions, no over-promotion", async () => {
    const venue3 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue3, { capacity: 4 });
    const confirmedUsers = await Promise.all([1, 2, 3, 4].map((i) => createUser(su, { name: `Conf${i}` })));
    const waitlistUsers = await Promise.all([1, 2].map((i) => createUser(su, { name: `Wait${i}` })));

    const confirmedParticipantIds = [];
    await withClients(async (open) => {
      for (const uid of confirmedUsers) {
        const c = await open("authenticated", uid);
        const r = await c.query(`select * from join_session($1, null, null, null)`, [s]);
        confirmedParticipantIds.push(r.rows[0].participant_id);
        assert.equal(r.rows[0].status, "confirmed");
      }
      for (const uid of waitlistUsers) {
        const c = await open("authenticated", uid);
        const r = await c.query(`select * from join_session($1, null, null, null)`, [s]);
        assert.equal(r.rows[0].status, "waitlisted");
      }

      const leaver1 = await open("authenticated", confirmedUsers[0]);
      const leaver2 = await open("authenticated", confirmedUsers[1]);

      await Promise.all([
        leaver1.query(`select leave_session($1, null)`, [confirmedParticipantIds[0]]),
        leaver2.query(`select leave_session($1, null)`, [confirmedParticipantIds[1]]),
      ]);

      const pending = await su.query(
        `select count(*) from session_participants where session_id = $1 and status = 'pending_confirmation'`,
        [s]
      );
      assert.equal(Number(pending.rows[0].count), 2, "both freed slots must have promoted exactly one waitlisted participant each");

      const occ = await su.query(
        `select count(*) from session_participants where session_id = $1 and status in ('confirmed','pending_confirmation')`,
        [s]
      );
      assert.equal(Number(occ.rows[0].count), 4, "capacity must be exactly filled, never exceeded");
    });
  });

  await t("concurrency", "promotion vs simultaneous join -> capacity invariant holds regardless of interleaving", async () => {
    const venue4 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue4, { sessionType: "singles", capacity: 2 });
    const confUser = await createUser(su, { name: "ConfX" });
    const waitUser = await createUser(su, { name: "WaitX" });
    const newJoiner = await createUser(su, { name: "NewJoiner" });

    let confParticipantId;
    await withClients(async (open) => {
      const cConf = await open("authenticated", confUser);
      const r1 = await cConf.query(`select * from join_session($1, null, null, null)`, [s]);
      confParticipantId = r1.rows[0].participant_id;

      const cWait = await open("authenticated", waitUser);
      await cWait.query(`select * from join_session($1, null, null, null)`, [s]); // waitlisted (capacity full)

      const cLeaver = await open("authenticated", confUser);
      const cNew = await open("authenticated", newJoiner);

      await Promise.all([
        cLeaver.query(`select leave_session($1, null)`, [confParticipantId]),
        cNew.query(`select * from join_session($1, null, null, null)`, [s]),
      ]);

      const occ = await su.query(
        `select count(*) from session_participants where session_id = $1 and status in ('confirmed','pending_confirmation')`,
        [s]
      );
      assert.ok(Number(occ.rows[0].count) <= 2, `capacity must not be exceeded, got ${occ.rows[0].count}`);
    });
  });

  await t("concurrency", "cancellation vs pending promotion -> session ends cancelled, no corruption", async () => {
    const venue5 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue5, { sessionType: "singles", capacity: 2 });
    const confUser = await createUser(su, { name: "ConfY" });
    const fillerUser = await createUser(su, { name: "FillerY" });
    const waitUser = await createUser(su, { name: "WaitY" });

    let confParticipantId, waitParticipantId;
    await withClients(async (open) => {
      const cConf = await open("authenticated", confUser);
      const r1 = await cConf.query(`select * from join_session($1, null, null, null)`, [s]);
      confParticipantId = r1.rows[0].participant_id;

      const cFiller = await open("authenticated", fillerUser);
      await cFiller.query(`select * from join_session($1, null, null, null)`, [s]); // fills the 2nd slot

      const cWait = await open("authenticated", waitUser);
      const r2 = await cWait.query(`select * from join_session($1, null, null, null)`, [s]);
      waitParticipantId = r2.rows[0].participant_id;
      assert.equal(r2.rows[0].status, "waitlisted");

      // Free one slot to create a pending_confirmation row for waitUser
      await cConf.query(`select leave_session($1, null)`, [confParticipantId]);
      const pendingCheck = await su.query(`select status from session_participants where id = $1`, [waitParticipantId]);
      assert.equal(pendingCheck.rows[0].status, "pending_confirmation");

      const organizerClient = await open("authenticated", organizerId);
      const waitClient = await open("authenticated", waitUser);

      await Promise.allSettled([
        organizerClient.query(`select cancel_session($1, $2)`, [s, "weather"]),
        waitClient.query(`select confirm_promotion($1, null)`, [waitParticipantId]),
      ]);

      const sessionRow = await su.query(`select status from sessions where id = $1`, [s]);
      assert.equal(sessionRow.rows[0].status, "cancelled");
    });
  });

  await t("concurrency", "expired promotion reverts to waitlisted and is NOT immediately re-selected", async () => {
    const venue6 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue6, { sessionType: "singles", capacity: 2 });
    const p1 = await createUser(su, { name: "WaitFirst" }); // joins waitlist first
    const p2 = await createUser(su, { name: "WaitSecond" }); // joins waitlist second
    const filler = await createUser(su, { name: "Filler" });
    const filler2 = await createUser(su, { name: "Filler2" });

    await withClients(async (open) => {
      const cFiller = await open("authenticated", filler);
      const rFiller = await cFiller.query(`select * from join_session($1, null, null, null)`, [s]);
      const fillerParticipantId = rFiller.rows[0].participant_id;

      const cFiller2 = await open("authenticated", filler2);
      await cFiller2.query(`select * from join_session($1, null, null, null)`, [s]); // fills the 2nd slot

      const c1 = await open("authenticated", p1);
      const r1 = await c1.query(`select * from join_session($1, null, null, null)`, [s]);
      const p1ParticipantId = r1.rows[0].participant_id;
      assert.equal(r1.rows[0].status, "waitlisted");

      const c2 = await open("authenticated", p2);
      const r2 = await c2.query(`select * from join_session($1, null, null, null)`, [s]);
      const p2ParticipantId = r2.rows[0].participant_id;
      assert.equal(r2.rows[0].status, "waitlisted");

      // Free the slot -> p1 (earliest) gets promoted to pending_confirmation
      await cFiller.query(`select leave_session($1, null)`, [fillerParticipantId]);
      const afterPromote = await su.query(`select status from session_participants where id = $1`, [p1ParticipantId]);
      assert.equal(afterPromote.rows[0].status, "pending_confirmation");

      // Force the promotion into the past so the sweep treats it as expired
      await su.query(
        `update session_participants set promotion_expires_at = now() - interval '1 minute' where id = $1`,
        [p1ParticipantId]
      );

      await su.query(`select expire_pending_promotions()`);

      const p1After = await su.query(`select status, waitlist_order_at from session_participants where id = $1`, [p1ParticipantId]);
      const p2After = await su.query(`select status, waitlist_order_at from session_participants where id = $1`, [p2ParticipantId]);

      assert.equal(p1After.rows[0].status, "waitlisted", "p1 must revert to waitlisted, not stay pending or confirmed");
      assert.equal(p2After.rows[0].status, "pending_confirmation", "p2 must be the one promoted next, not p1 again");
      assert.ok(
        new Date(p1After.rows[0].waitlist_order_at) > new Date(p2After.rows[0].waitlist_order_at),
        "p1's waitlist_order_at must be bumped to the back of the line"
      );
    });
  });

  await t("concurrency", "guest duplicate handling: same contact cannot join twice actively", async () => {
    const venue7 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue7, { capacity: 4 });
    await withClients(async (open) => {
      const c = await open("anon");
      await c.query(`select * from join_session($1, $2, $3, $4)`, [s, "Dup Guest", "email", "dup@example.com"]);
      await assert.rejects(
        c.query(`select * from join_session($1, $2, $3, $4)`, [s, "Dup Guest Again", "email", "DUP@example.com"]),
        /already joined/i
      );
    });
  });

  await t("concurrency", "registered duplicate join is prevented", async () => {
    const venue8 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue8, { capacity: 4 });
    const dupUser = await createUser(su, { name: "Dup Registered" });
    await withClients(async (open) => {
      const c = await open("authenticated", dupUser);
      await c.query(`select * from join_session($1, null, null, null)`, [s]);
      await assert.rejects(
        c.query(`select * from join_session($1, null, null, null)`, [s]),
        /already joined/i
      );
    });
  });

  // =======================================================================
  // SECTION 4 — REMINDER IDEMPOTENCY (9 cases)
  // =======================================================================

  await t("reminders", "1. join before reminder window -> exactly one reminder enqueued", async () => {
    const venue9 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue9, { capacity: 4, startOffsetMin: 30 });
    const u = await createUser(su, { name: "RemA" });
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select * from join_session($1, null, null, null)`, [s]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    const r = await su.query(
      `select count(*) from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(Number(r.rows[0].count), 1);
  });

  await t("reminders", "2. join after first sweep -> late joiner gets their own reminder, no duplicate for the first", async () => {
    const venue10 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue10, { capacity: 4, startOffsetMin: 30 });
    const u1 = await createUser(su, { name: "RemB1" });
    const u2 = await createUser(su, { name: "RemB2" });
    await withClients(async (open) => {
      const c1 = await open("authenticated", u1);
      await c1.query(`select * from join_session($1, null, null, null)`, [s]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    await withClients(async (open) => {
      const c2 = await open("authenticated", u2);
      await c2.query(`select * from join_session($1, null, null, null)`, [s]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    const r = await su.query(
      `select user_id from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(r.rows.length, 2);
  });

  await t("reminders", "3. leave and rejoin -> no second reminder for the same user+session", async () => {
    const venue11 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue11, { capacity: 4, startOffsetMin: 30 });
    const u = await createUser(su, { name: "RemC" });
    let pid;
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      const r1 = await c.query(`select * from join_session($1, null, null, null)`, [s]);
      pid = r1.rows[0].participant_id;
    });
    await su.query(`select enqueue_session_reminders(90)`);
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select leave_session($1, null)`, [pid]);
      await c.query(`select * from join_session($1, null, null, null)`, [s]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    const r = await su.query(
      `select count(*) from notification_outbox where session_id = $1 and user_id = $2 and event_type = 'session_reminder'`,
      [s, u]
    );
    assert.equal(Number(r.rows[0].count), 1, "rejoin must not produce a second reminder row");
  });

  await t("reminders", "4. session time change -> unsent reminder cleared, fresh one enqueued for new time", async () => {
    const venue12 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue12, { capacity: 4, startOffsetMin: 30 });
    const u = await createUser(su, { name: "RemD" });
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select * from join_session($1, null, null, null)`, [s]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    const before = await su.query(
      `select id from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(before.rows.length, 1);

    // Move the start time -- still within window, but the trigger must clear
    // the now-stale unsent reminder row.
    await su.query(
      `update sessions set start_time = start_time + interval '20 minutes', end_time = end_time + interval '20 minutes' where id = $1`,
      [s]
    );
    const afterTimeChange = await su.query(
      `select id from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(afterTimeChange.rows.length, 0, "unsent reminder must be cleared on time change");

    await su.query(`select enqueue_session_reminders(90)`);
    const after = await su.query(
      `select id from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(after.rows.length, 1, "a fresh reminder must be enqueued for the new time");
  });

  await t("reminders", "4b. already-SENT reminder is not clawed back on time change", async () => {
    const venue13 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue13, { capacity: 4, startOffsetMin: 30 });
    const u = await createUser(su, { name: "RemE" });
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select * from join_session($1, null, null, null)`, [s]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    await su.query(
      `update notification_outbox set sent_at = now() where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    await su.query(
      `update sessions set start_time = start_time + interval '20 minutes', end_time = end_time + interval '20 minutes' where id = $1`,
      [s]
    );
    const r = await su.query(
      `select sent_at from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(r.rows.length, 1, "the sent row must remain");
    assert.ok(r.rows[0].sent_at, "must still be marked sent");
  });

  await t("reminders", "5. cancellation -> no reminder enqueued for a cancelled session", async () => {
    const venue14 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue14, { capacity: 4, startOffsetMin: 30 });
    const u = await createUser(su, { name: "RemF" });
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select * from join_session($1, null, null, null)`, [s]);
      const organizerClient = await open("authenticated", organizerId);
      await organizerClient.query(`select cancel_session($1, $2)`, [s, "test cancel"]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    const r = await su.query(
      `select count(*) from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(Number(r.rows[0].count), 0);
  });

  await t("reminders", "6. recreated session is independent -- no conflict with an old session's reminders", async () => {
    const venue15 = await createVenue(su, organizerId);
    const sOld = await createSession(su, organizerId, venue15, { capacity: 4, startOffsetMin: 30 });
    const u = await createUser(su, { name: "RemG" });
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select * from join_session($1, null, null, null)`, [sOld]);
    });
    await su.query(`select enqueue_session_reminders(90)`);

    const sNew = await createSession(su, organizerId, venue15, { capacity: 4, startOffsetMin: 30 });
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select * from join_session($1, null, null, null)`, [sNew]);
    });
    await su.query(`select enqueue_session_reminders(90)`);

    const r = await su.query(
      `select session_id from notification_outbox where user_id = $1 and event_type = 'session_reminder'`,
      [u]
    );
    assert.equal(r.rows.length, 2, "both the old and new session must each have their own reminder row");
  });

  await t("reminders", "7. worker retries: repeated sweeps do not duplicate", async () => {
    const venue16 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue16, { capacity: 4, startOffsetMin: 30 });
    const u = await createUser(su, { name: "RemH" });
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select * from join_session($1, null, null, null)`, [s]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    await su.query(`select enqueue_session_reminders(90)`);
    await su.query(`select enqueue_session_reminders(90)`);
    const r = await su.query(
      `select count(*) from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(Number(r.rows[0].count), 1);
  });

  await t("reminders", "8. delivery failure: unsent row persists with incremented attempts, not re-created", async () => {
    const venue17 = await createVenue(su, organizerId);
    const s = await createSession(su, organizerId, venue17, { capacity: 4, startOffsetMin: 30 });
    const u = await createUser(su, { name: "RemI" });
    await withClients(async (open) => {
      const c = await open("authenticated", u);
      await c.query(`select * from join_session($1, null, null, null)`, [s]);
    });
    await su.query(`select enqueue_session_reminders(90)`);
    await su.query(
      `update notification_outbox set attempts = attempts + 1 where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    await su.query(`select enqueue_session_reminders(90)`); // simulated retry sweep
    const r = await su.query(
      `select attempts, sent_at from notification_outbox where session_id = $1 and event_type = 'session_reminder'`,
      [s]
    );
    assert.equal(r.rows.length, 1, "still exactly one row, not duplicated by the retry");
    assert.equal(r.rows[0].attempts, 1);
    assert.equal(r.rows[0].sent_at, null);
  });

  await t("reminders", "9. push token reassignment: delivery-time lookup always reflects the current owner", async () => {
    // A token identifies a DEVICE, which can be reused across accounts
    // (logout/login as someone else on the same phone). Registering the
    // SAME token string under a new user must reassign it, not duplicate
    // it -- this is what register_push_token()'s ON CONFLICT(token) does.
    const userA = await createUser(su, { name: "RemJ-A" });
    const userB = await createUser(su, { name: "RemJ-B" });
    const sharedToken = "shared-device-token";
    await withClients(async (open) => {
      const cA = await open("authenticated", userA);
      await cA.query(`select register_push_token($1, $2)`, [sharedToken, "android"]);

      const cB = await open("authenticated", userB);
      await cB.query(`select register_push_token($1, $2)`, [sharedToken, "android"]);
    });
    const r = await su.query(`select user_id from push_tokens where token = $1`, [sharedToken]);
    assert.equal(r.rows.length, 1, "exactly one row must exist for a given token");
    assert.equal(r.rows[0].user_id, userB, "the token must now belong to the new registering user, not the old one");
  });

  // =======================================================================
  // SECTION 5 — REPORTS / BLOCKS
  // =======================================================================

  await t("reports", "self-report is rejected", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", playerBId);
      await assert.rejects(
        c.query(`select submit_report($1, $2, $3)`, [playerBId, null, "myself"]),
        /cannot report yourself/i
      );
    });
  });

  await t("reports", "general report: rapid duplicate within 5 minutes returns the same row", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      const r1 = await c.query(`select submit_report($1, $2, $3) as id`, [playerBId, null, "rude"]);
      const r2 = await c.query(`select submit_report($1, $2, $3) as id`, [playerBId, null, "rude again"]);
      assert.equal(r1.rows[0].id, r2.rows[0].id);
      const count = await su.query(
        `select count(*) from reports where reporter_user_id = $1 and reported_user_id = $2 and session_id is null`,
        [nonMemberId, playerBId]
      );
      assert.equal(Number(count.rows[0].count), 1);
    });
  });

  await t("reports", "general report: a genuinely later report (outside the window) creates a new row", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      const existing = await su.query(
        `select id from reports where reporter_user_id = $1 and reported_user_id = $2 and session_id is null`,
        [nonMemberId, playerBId]
      );
      await su.query(`update reports set created_at = now() - interval '10 minutes' where id = $1`, [existing.rows[0].id]);
      const r2 = await c.query(`select submit_report($1, $2, $3) as id`, [playerBId, null, "new complaint"]);
      assert.notEqual(r2.rows[0].id, existing.rows[0].id);
    });
  });

  await t("reports", "session-scoped report: duplicate returns existing row permanently (not time-limited)", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      const r1 = await c.query(`select submit_report($1, $2, $3) as id`, [playerBId, sessionId, "session incident"]);
      const r2 = await c.query(`select submit_report($1, $2, $3) as id`, [playerBId, sessionId, "session incident again"]);
      assert.equal(r1.rows[0].id, r2.rows[0].id);
    });
  });

  await t("reports", "self-block is rejected by CHECK constraint", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", playerBId);
      await assert.rejects(
        c.query(`insert into blocks (blocked_user_id) values ($1)`, [playerBId]),
        /blocks_no_self_block/i
      );
    });
  });

  await t("reports", "duplicate block is rejected by UNIQUE constraint", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      await c.query(`insert into blocks (blocked_user_id) values ($1)`, [playerBId]);
      await assert.rejects(
        c.query(`insert into blocks (blocked_user_id) values ($1)`, [playerBId]),
        /blocks_unique/i
      );
    });
  });

  // =======================================================================
  // SECTION 5b — report_session_participant() / block_session_participant()
  // (migration 022 -- the MVP-gate additive report/block RPCs)
  // =======================================================================

  const rbVenueId = venueId; // reuse; staffUserId is already staff here
  const rbSessionId = await createSession(su, organizerId, rbVenueId, { capacity: 4 });
  const playerXId = await createUser(su, { name: "Player X" });
  const playerYId = await createUser(su, { name: "Player Y" });
  let playerXParticipantId, playerYParticipantId;
  await withClients(async (open) => {
    const xc = await open("authenticated", playerXId);
    const xr = await xc.query(`select * from join_session($1, null, null, null)`, [rbSessionId]);
    playerXParticipantId = xr.rows[0].participant_id;
    const yc = await open("authenticated", playerYId);
    const yr = await yc.query(`select * from join_session($1, null, null, null)`, [rbSessionId]);
    playerYParticipantId = yr.rows[0].participant_id;
  });

  // A guest participant of the SAME session, for the guest-target cases.
  let rbGuestParticipantId;
  await withClients(async (open) => {
    const anonC = await open("anon");
    const gr = await anonC.query(`select * from join_session($1, $2, $3, $4)`, [
      rbSessionId,
      "Guest RB",
      "email",
      "guest-rb@example.com",
    ]);
    rbGuestParticipantId = gr.rows[0].participant_id;
  });

  // A completely separate session/participant, for the cross-session case.
  const otherSessionId = await createSession(su, organizerId, rbVenueId, { capacity: 4 });
  const playerZId = await createUser(su, { name: "Player Z" });
  await withClients(async (open) => {
    const zc = await open("authenticated", playerZId);
    await zc.query(`select * from join_session($1, null, null, null)`, [otherSessionId]);
  });

  await t("report_block_rpc", "A1: joined participant can report another registered participant in the same session", async () => {
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      const r = await xc.query(`select report_session_participant($1, $2) as id`, [
        playerYParticipantId,
        "unsportsmanlike conduct",
      ]);
      assert.ok(r.rows[0].id, "must return a report id");
      const row = await su.query(`select reporter_user_id, reported_user_id from reports where id = $1`, [
        r.rows[0].id,
      ]);
      assert.equal(row.rows[0].reporter_user_id, playerXId);
      assert.equal(row.rows[0].reported_user_id, playerYId);
    });
  });

  await t("report_block_rpc", "A2: organizer can report a registered participant in their session", async () => {
    await withClients(async (open) => {
      const oc = await open("authenticated", organizerId);
      const r = await oc.query(`select report_session_participant($1, $2) as id`, [
        playerYParticipantId,
        "organizer report",
      ]);
      assert.ok(r.rows[0].id);
    });
  });

  await t("report_block_rpc", "A3: venue staff can report a registered participant in that venue's session", async () => {
    await withClients(async (open) => {
      const sc = await open("authenticated", staffUserId);
      const r = await sc.query(`select report_session_participant($1, $2) as id`, [
        playerYParticipantId,
        "staff report",
      ]);
      assert.ok(r.rows[0].id);
    });
  });

  await t("report_block_rpc", "A4: non-member cannot report a participant from that session", async () => {
    await withClients(async (open) => {
      const nc = await open("authenticated", nonMemberId);
      await assert.rejects(
        nc.query(`select report_session_participant($1, $2)`, [playerYParticipantId, "nope"]),
        /not authorized/i
      );
    });
  });

  await t("report_block_rpc", "A5: participant of a DIFFERENT session cannot use its participant_id here", async () => {
    await withClients(async (open) => {
      const zc = await open("authenticated", playerZId);
      // playerZ is joined to otherSessionId, not rbSessionId -- targeting a
      // participant of rbSessionId must be rejected exactly like non-membership.
      await assert.rejects(
        zc.query(`select report_session_participant($1, $2)`, [playerYParticipantId, "cross session"]),
        /not authorized/i
      );
    });
  });

  await t("report_block_rpc", "A6: self-report via the RPC is rejected", async () => {
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      await assert.rejects(
        xc.query(`select report_session_participant($1, $2)`, [playerXParticipantId, "myself"]),
        /cannot report yourself/i
      );
    });
  });

  await t("report_block_rpc", "A7: guest target is rejected generically -- no 'guest' wording, no distinguishable message", async () => {
    // Threat model: an authorized (joined/organizer/staff) caller, working
    // from real get_session_roster() participant_ids for their OWN session,
    // can only ever get one of two outcomes for a real row: success (target
    // is registered), or this one generic failure (target is a guest) --
    // there is no third "other reason" outcome in that scenario to compare
    // it against, so the meaningful assertions are about the message's
    // OWN wording, not equality with an unrelated (unauthorized-caller /
    // nonexistent-id) scenario, which is intentionally a different bucket
    // (see the function's own comments on why "not found" and "not a
    // member of this session" share a message instead).
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      const err = await xc
        .query(`select report_session_participant($1, $2)`, [rbGuestParticipantId, "guest"])
        .catch((e) => e);
      assert.ok(err instanceof Error, "guest target must be rejected");
      assert.ok(!/guest/i.test(err.message), "error text must never mention 'guest'");
      assert.ok(!/cannot report yourself/i.test(err.message), "must not be confused with self-report");
      assert.match(err.message, /unable to complete this action/i);
    });
  });

  await t("report_block_rpc", "A8: repeated report is idempotent (no duplicate row) -- session_id is always resolved server-side here, so this goes through the PERMANENT session-scoped uniqueness constraint (a strictly stronger guarantee than the 5-minute general-report window, which only applies when session_id is NULL and is therefore never reached by this RPC)", async () => {
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      const r1 = await xc.query(`select report_session_participant($1, $2) as id`, [
        playerYParticipantId,
        "first",
      ]);
      const r2 = await xc.query(`select report_session_participant($1, $2) as id`, [
        playerYParticipantId,
        "second",
      ]);
      assert.equal(r1.rows[0].id, r2.rows[0].id);
    });
  });

  await t("report_block_rpc", "A9: existing session-scoped reports uniqueness constraint still governs the underlying row", async () => {
    const count = await su.query(
      `select count(*) from reports where reporter_user_id = $1 and reported_user_id = $2 and session_id = $3`,
      [playerXId, playerYId, rbSessionId]
    );
    assert.equal(Number(count.rows[0].count), 1, "no duplicate row despite 3 calls above (A1 + A8 x2)");
  });

  await t("report_block_rpc", "A10: the RPC response never contains the target's user_id", async () => {
    await withClients(async (open) => {
      const oc = await open("authenticated", organizerId);
      const r = await oc.query(`select report_session_participant($1, $2) as id`, [
        playerYParticipantId,
        "id-leak-check",
      ]);
      const returned = r.rows[0].id;
      assert.notEqual(returned, playerYId, "must not return the target user id");
      const asReportId = await su.query(`select 1 from reports where id = $1`, [returned]);
      assert.equal(asReportId.rows.length, 1, "returned value must be a reports.id, not a user id");
    });
  });

  await t("report_block_rpc", "B1: joined participant can block another registered participant in the same session", async () => {
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      await xc.query(`select block_session_participant($1)`, [playerYParticipantId]);
      const row = await su.query(`select 1 from blocks where blocker_user_id = $1 and blocked_user_id = $2`, [
        playerXId,
        playerYId,
      ]);
      assert.equal(row.rows.length, 1);
      // Clean up so later tests in this section can re-block without hitting
      // the uniqueness constraint prematurely.
      await su.query(`delete from blocks where blocker_user_id = $1 and blocked_user_id = $2`, [
        playerXId,
        playerYId,
      ]);
    });
  });

  await t("report_block_rpc", "B2: organizer can block a registered participant in their session", async () => {
    await withClients(async (open) => {
      const oc = await open("authenticated", organizerId);
      await oc.query(`select block_session_participant($1)`, [playerYParticipantId]);
      await su.query(`delete from blocks where blocker_user_id = $1 and blocked_user_id = $2`, [
        organizerId,
        playerYId,
      ]);
    });
  });

  await t("report_block_rpc", "B3: venue staff can block a registered participant in that venue's session", async () => {
    await withClients(async (open) => {
      const sc = await open("authenticated", staffUserId);
      await sc.query(`select block_session_participant($1)`, [playerYParticipantId]);
      await su.query(`delete from blocks where blocker_user_id = $1 and blocked_user_id = $2`, [
        staffUserId,
        playerYId,
      ]);
    });
  });

  await t("report_block_rpc", "B4: non-member cannot block a participant from that session", async () => {
    await withClients(async (open) => {
      const nc = await open("authenticated", nonMemberId);
      await assert.rejects(
        nc.query(`select block_session_participant($1)`, [playerYParticipantId]),
        /not authorized/i
      );
    });
  });

  await t("report_block_rpc", "B5: participant of a DIFFERENT session cannot use its participant_id here", async () => {
    await withClients(async (open) => {
      const zc = await open("authenticated", playerZId);
      await assert.rejects(
        zc.query(`select block_session_participant($1)`, [playerYParticipantId]),
        /not authorized/i
      );
    });
  });

  await t("report_block_rpc", "B6: self-block via the RPC is rejected by the existing CHECK constraint", async () => {
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      await assert.rejects(
        xc.query(`select block_session_participant($1)`, [playerXParticipantId]),
        /blocks_no_self_block/i
      );
    });
  });

  await t("report_block_rpc", "B7: guest target is rejected generically -- no 'guest' wording", async () => {
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      const err = await xc
        .query(`select block_session_participant($1)`, [rbGuestParticipantId])
        .catch((e) => e);
      assert.ok(err instanceof Error);
      assert.ok(!/guest/i.test(err.message), "error text must never mention 'guest'");
      assert.ok(!/self.?block/i.test(err.message), "must not be confused with self-block");
      assert.match(err.message, /unable to complete this action/i);
    });
  });

  await t("report_block_rpc", "B8: existing blocks UNIQUE constraint still governs repeated blocks", async () => {
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      await xc.query(`select block_session_participant($1)`, [playerYParticipantId]);
      await assert.rejects(
        xc.query(`select block_session_participant($1)`, [playerYParticipantId]),
        /blocks_unique/i
      );
      await su.query(`delete from blocks where blocker_user_id = $1 and blocked_user_id = $2`, [
        playerXId,
        playerYId,
      ]);
    });
  });

  await t("report_block_rpc", "B9: block_session_participant() returns void -- never a user_id", async () => {
    await withClients(async (open) => {
      const xc = await open("authenticated", playerXId);
      const r = await xc.query(`select block_session_participant($1) as result`, [playerYParticipantId]);
      // node-pg serializes SQL `void` as an empty string, not JS null/undefined
      // -- assert on that concretely, plus the actual security property
      // (the value is trivially not a uuid, so it cannot be the target's id).
      const value = r.rows[0].result;
      assert.equal(value, "", "void must serialize as an empty value, nothing identity-bearing");
      assert.notEqual(value, playerYId);
      await su.query(`delete from blocks where blocker_user_id = $1 and blocked_user_id = $2`, [
        playerXId,
        playerYId,
      ]);
    });
  });

  await t("report_block_rpc", "D: function hardening -- EXECUTE revoked from PUBLIC, granted only to authenticated", async () => {
    const rows = await su.query(`
      select p.proname,
             has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can,
             has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_can,
             has_function_privilege('service_role', p.oid, 'EXECUTE') as service_can,
             p.prosecdef as is_security_definer
      from pg_proc p
      where p.proname in ('report_session_participant', 'block_session_participant')
    `);
    assert.equal(rows.rows.length, 2, "both functions must exist");
    for (const row of rows.rows) {
      assert.equal(row.is_security_definer, true, `${row.proname} must be SECURITY DEFINER`);
      assert.equal(row.anon_can, false, `${row.proname} must not be callable by anon`);
      assert.equal(row.auth_can, true, `${row.proname} must be callable by authenticated`);
      assert.equal(row.service_can, false, `${row.proname} must not be granted to service_role (not needed/not requested)`);
    }
  });

  await t("report_block_rpc", "no dynamic SQL in either function (static source check)", async () => {
    const rows = await su.query(`
      select p.proname, pg_get_functiondef(p.oid) as def
      from pg_proc p
      where p.proname in ('report_session_participant', 'block_session_participant')
    `);
    for (const row of rows.rows) {
      assert.ok(
        !/execute\s+format|execute\s+'/i.test(row.def),
        `${row.proname} must not use dynamic SQL (EXECUTE ... / EXECUTE format(...))`
      );
      assert.ok(/search_path.*pg_catalog.*public/i.test(row.def), `${row.proname} must set search_path`);
    }
  });

  // =======================================================================
  // SECTION 6 — MISC CONSTRAINTS
  // =======================================================================

  await t("constraints", "venue number_of_courts = 0 is rejected (must be NULL or >= 1)", async () => {
    await assert.rejects(
      su.query(
        `insert into venues (name, location, number_of_courts, created_by) values ('Zero Court Venue', point(0,0), 0, $1)`,
        [organizerId]
      ),
      /venues_number_of_courts_check/i
    );
  });

  await t("constraints", "is_venue_managed reflects venue_staff existence, identities not exposed", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      const managed = await c.query(`select is_venue_managed($1) as m`, [venueId]);
      assert.equal(managed.rows[0].m, true);

      const freshVenue = await createVenue(su, organizerId);
      const unmanaged = await c.query(`select is_venue_managed($1) as m`, [freshVenue]);
      assert.equal(unmanaged.rows[0].m, false);

      await assert.rejects(
        c.query(`select * from venue_staff where venue_id = $1`, [venueId]),
        /permission denied/i
      );
    });
  });

  // =======================================================================
  // SECTION 7 — GRANTS FIX (migration 023): TRUNCATE denial + intended
  // privileges still work, for every table the live verification found
  // over-privileged.
  // =======================================================================

  const truncateTargets = [
    { table: "sessions", roles: ["anon", "authenticated"] },
    { table: "venues", roles: ["anon", "authenticated"] },
    { table: "venue_staff", roles: ["anon", "authenticated"] },
    { table: "guest_contacts", roles: ["authenticated"] },
    { table: "push_tokens", roles: ["authenticated"] },
    { table: "blocks", roles: ["authenticated"] },
    { table: "reports", roles: ["authenticated"] },
    { table: "public_profiles", roles: ["anon", "authenticated"] },
  ];

  for (const { table, roles } of truncateTargets) {
    for (const role of roles) {
      await t("grants", `TRUNCATE ${table} denied for ${role}`, async () => {
        await withClients(async (open) => {
          const c = await open(role, role === "authenticated" ? nonMemberId : undefined);
          // A view (public_profiles) fails TRUNCATE structurally ("is not
          // a table") regardless of grants -- still a correct denial, just
          // a different error than a real table's grant-level rejection.
          await assert.rejects(
            c.query(`truncate table ${table}`),
            /permission denied|is not a table/i
          );
        });
      });
    }
  }

  await t("grants", "intended SELECT still works: anon can read sessions/venues/public_profiles", async () => {
    await withClients(async (open) => {
      const c = await open("anon");
      await c.query(`select * from sessions where id = $1`, [sessionId]);
      await c.query(`select * from venues where id = $1`, [venueId]);
      await c.query(`select * from public_profiles where id = $1`, [organizerId]);
    });
  });

  await t("grants", "intended INSERT still works: authenticated can create a venue and a session", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", organizerId);
      const v = await c.query(
        `insert into venues (name, location, number_of_courts, created_by) values ('Grants Check Venue', point(0,0), 2, $1) returning id`,
        [organizerId]
      );
      await c.query(
        `insert into sessions (venue_id, created_by, session_type, start_time, end_time, capacity)
         values ($1, $2, 'singles', now() + interval '1 day', now() + interval '1 day 1 hour', 2)`,
        [v.rows[0].id, organizerId]
      );
    });
  });

  await t("grants", "intended UPDATE still works: organizer can edit their own venue/session", async () => {
    await withClients(async (open) => {
      const c = await open("authenticated", organizerId);
      await c.query(`update venues set hours_info = 'Mon-Fri 9-5' where id = $1`, [venueId]);
      await c.query(`update sessions set skill_level_info = 'intermediate' where id = $1`, [sessionId]);
    });
  });

  await t("grants", "intended DELETE still works: authenticated can delete their own block row", async () => {
    const freshTarget = await createUser(su, { name: "Grants Delete Target" });
    await withClients(async (open) => {
      const c = await open("authenticated", nonMemberId);
      await c.query(`insert into blocks (blocked_user_id) values ($1)`, [freshTarget]);
      const del = await c.query(`delete from blocks where blocked_user_id = $1`, [freshTarget]);
      assert.equal(del.rowCount, 1);
    });
  });

  await t("grants", "SECURITY DEFINER RPCs still work after the grants fix (join_session, get_session_roster, cancel_session path)", async () => {
    await withClients(async (open) => {
      const freshVenue = await createVenue(su, organizerId);
      const freshSession = await createSession(su, organizerId, freshVenue, { capacity: 2, sessionType: "singles" });
      const joiner = await createUser(su, { name: "Grants RPC Joiner" });
      const c = await open("authenticated", joiner);
      const r = await c.query(`select * from join_session($1, null, null, null)`, [freshSession]);
      assert.equal(r.rows[0].status, "confirmed");
      const roster = await c.query(`select * from get_session_roster($1)`, [freshSession]);
      assert.equal(roster.rows.length, 1);

      const oc = await open("authenticated", organizerId);
      await oc.query(`select cancel_session($1, $2)`, [freshSession, "grants regression check"]);
      const check = await su.query(`select status from sessions where id = $1`, [freshSession]);
      assert.equal(check.rows[0].status, "cancelled");
    });
  });

  // =======================================================================
  await su.end();
  printReport();
}

function printReport() {
  const order = [
    "privacy",
    "attack",
    "concurrency",
    "reminders",
    "reports",
    "report_block_rpc",
    "constraints",
    "grants",
  ];
  let pass = 0, fail = 0, blockedN = 0, notTested = 0;
  for (const cat of order) {
    const rows = results.filter((r) => r.category === cat);
    if (rows.length === 0) continue;
    console.log(`\n=== ${cat.toUpperCase()} ===`);
    for (const r of rows) {
      console.log(`[${r.status}] ${r.name}${r.detail ? " -- " + r.detail : ""}`);
      if (r.status === "PASS") pass++;
      else if (r.status === "FAIL") fail++;
      else if (r.status === "BLOCKED") blockedN++;
      else notTested++;
    }
  }
  // Guard against the exact class of bug this just caught: a result whose
  // category isn't in `order` above would silently vanish from both the
  // printed breakdown and the PASS/FAIL/BLOCKED tally while still counting
  // toward TOTAL, making the summary internally inconsistent (PASS+FAIL+
  // BLOCKED+NOT_TESTED != TOTAL) without ever saying why.
  const uncategorized = results.filter((r) => !order.includes(r.category));
  if (uncategorized.length > 0) {
    console.log(`\n=== UNCATEGORIZED (missing from printReport's \`order\` list!) ===`);
    for (const r of uncategorized) {
      console.log(`[${r.status}] (${r.category}) ${r.name}${r.detail ? " -- " + r.detail : ""}`);
      if (r.status === "PASS") pass++;
      else if (r.status === "FAIL") fail++;
      else if (r.status === "BLOCKED") blockedN++;
      else notTested++;
    }
  }
  console.log(`\n=== SUMMARY ===`);
  console.log(`PASS: ${pass}  FAIL: ${fail}  BLOCKED: ${blockedN}  NOT TESTED: ${notTested}  TOTAL: ${results.length}`);
  if (pass + fail + blockedN + notTested !== results.length) {
    console.log(`WARNING: tally (${pass + fail + blockedN + notTested}) != TOTAL (${results.length}) -- a category is still missing from \`order\`.`);
    process.exitCode = 1;
  }
  if (fail > 0) process.exitCode = 1;
}

main().catch((err) => {
  console.error("FATAL test-runner error:", err);
  process.exit(1);
});
