import { Pool } from "pg";

const connectionString = process.env.CLAIMS_DATABASE_URL;

if (!connectionString) {
  throw new Error("CLAIMS_DATABASE_URL is not set in .env.local");
}

const globalForClaimsPg = globalThis as unknown as {
  claimsPgPool?: Pool;
};

export const claimsPool =
  globalForClaimsPg.claimsPgPool ??
  new Pool({
    connectionString,
    max: 5,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
  });

if (process.env.NODE_ENV !== "production") {
  globalForClaimsPg.claimsPgPool = claimsPool;
}