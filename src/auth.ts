
import NextAuth from "next-auth";
import Credentials from "next-auth/providers/credentials";
import bcrypt from "bcryptjs";
import { pool } from "@/lib/db";

export const { handlers, auth, signIn, signOut } = NextAuth({
  session: {
    strategy: "jwt",
  },

  providers: [
    Credentials({
      name: "Credentials",
      credentials: {
        email: { label: "Email", type: "email" },
        password: { label: "Password", type: "password" },
      },

      async authorize(credentials) {
        const email =
          typeof credentials.email === "string"
            ? credentials.email.trim().toLowerCase()
            : "";
        const password =
          typeof credentials.password === "string"
            ? credentials.password
            : "";

        if (!email || !password) return null;

        // Check resident account first.
        const residentResult = await pool.query(
          `SELECT resident_id, name, email, password_hash
           FROM resident
           WHERE LOWER(email) = $1 AND resident_status = 'active'`,
          [email]
        );

        if (residentResult.rows.length > 0) {
          const resident = residentResult.rows[0];
          const passwordMatches = await bcrypt.compare(
            password,
            resident.password_hash
          );

          if (!passwordMatches) return null;

          return {
            id: String(resident.resident_id),
            name: resident.name,
            email: resident.email,
            role: "resident",
            residentId: resident.resident_id,
          };
        }

        // Otherwise check staff/admin account.
        const staffResult = await pool.query(
          `SELECT staff_id, name, email, password_hash, role
           FROM staff
           WHERE LOWER(email) = $1 AND active = TRUE`,
          [email]
        );

        if (staffResult.rows.length === 0) return null;

        const staff = staffResult.rows[0];
        const passwordMatches = await bcrypt.compare(
          password,
          staff.password_hash
        );

        if (!passwordMatches) return null;

        return {
          id: String(staff.staff_id),
          name: staff.name,
          email: staff.email,
          role: staff.role,
          staffId: staff.staff_id,
        };
      },
    }),
  ],

  callbacks: {
    async jwt({ token, user }) {
      if (user) {
        token.role = user.role;
        token.residentId = user.residentId;
        token.staffId = user.staffId;
      }

      return token;
    },

    async session({ session, token }) {
      if (session.user) {
        session.user.role = token.role;
        session.user.residentId = token.residentId;
        session.user.staffId = token.staffId;
      }

      return session;
    },
  },

  pages: {
    signIn: "/login",
  },
});
