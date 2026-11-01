import "next-auth";
import "next-auth/jwt";
import type { DefaultSession } from "next-auth";
declare module "next-auth" {
  interface User {
    role?: "resident" | "staff";
    residentId?: number;
    staffId?: number;
  }

  interface Session {
    user: {
      role?: "resident" | "staff";
      residentId?: number;
      staffId?: number;
    } & DefaultSession["user"];
  }
}

declare module "next-auth/jwt" {
  interface JWT {
    role?: "resident" | "staff";
    residentId?: number;
    staffId?: number;
  }
}