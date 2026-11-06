import { createHmac, randomBytes } from "node:crypto";
import { claimsPool } from "@/lib/claims-db";
import type { PoolClient } from "pg";

export type ClaimsAction =
  | "claim:approve"
  | "claim:reject"
  | "handover:record";

function base64url(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}

function createAssertion(staffId: number, action: ClaimsAction): string {
  const secretHex = process.env.CLAIMS_HMAC_KEY_HEX;
  const kid = process.env.CLAIMS_KEY_ID;

  if (!secretHex || !/^[0-9a-fA-F]{64}$/.test(secretHex)) {
    throw new Error("CLAIMS_HMAC_KEY_HEX must be a 32-byte hexadecimal key");
  }

  if (!kid || !/^[A-Za-z0-9._-]{1,64}$/.test(kid)) {
    throw new Error("CLAIMS_KEY_ID is missing or invalid");
  }

  const now = Math.floor(Date.now() / 1000);

  const header = {
    alg: "HS256",
    typ: "JWT",
    kid,
  };

  const payload = {
    iss: "lost-found-web",
    aud: "lost-found-claims-db",
    sub: `staff:${staffId}`,
    iat: now,
    exp: now + 60,
    jti: randomBytes(32).toString("base64url"),
    scope: action,
  };

  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(
    JSON.stringify(payload)
  )}`;

  const signature = createHmac(
    "sha256",
    Buffer.from(secretHex, "hex")
  )
    .update(unsigned, "utf8")
    .digest("base64url");

  return `${unsigned}.${signature}`;
}

export async function executeClaimsAction<T>(
  staffId: number,
  action: ClaimsAction,
  sql: string,
  parameters: unknown[]
): Promise<T> {
  if (!Number.isInteger(staffId) || staffId <= 0) {
    throw new Error("Invalid authenticated staff identity");
  }

  const assertion = createAssertion(staffId, action);

  const businessClient: PoolClient = await claimsPool.connect();
  let reservationClient: PoolClient | undefined;

  try {
    await businessClient.query("BEGIN");

    const transactionInfo = await businessClient.query(`
      SELECT
        pg_backend_pid() AS backend_pid,
        pg_current_xact_id()::text AS transaction_id
    `);

    const backendPid = transactionInfo.rows[0].backend_pid;
    const transactionId = transactionInfo.rows[0].transaction_id;

    reservationClient = await claimsPool.connect();

    await reservationClient.query(
      `CALL claims_private.reserve_assertion($1, $2, $3::xid8)`,
      [assertion, backendPid, transactionId]
    );

    reservationClient.release();
    reservationClient = undefined;
    console.log("assertion parts:", assertion.split(".").length, "params:", [...parameters, "<assertion>"]);
    const result = await businessClient.query(sql, [
      ...parameters,
      assertion,
    ]);

    await businessClient.query("COMMIT");

    return result.rows[0] as T;
  } catch (error) {
    await businessClient.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    reservationClient?.release();
    businessClient.release();
  }
}
