import "next-auth";
import "next-auth/jwt";

declare module "next-auth" {
  interface Session {
    user: {
      id?: string;
      role?: "resident" | "staff" | "admin";
      residentId?: number;
      staffId?: number;
    } & DefaultSession["user"];
  }

  interface User {
    role?: "resident" | "staff" | "admin";
    residentId?: number;
    staffId?: number;
  }
}

declare module "next-auth/jwt" {
  interface JWT {
    role?: "resident" | "staff" | "admin";
    residentId?: number;
    staffId?: number;
  }
}