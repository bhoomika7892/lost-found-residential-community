
"use client";

import { FormEvent, useState } from "react";
import { signIn, signOut, getSession } from "next-auth/react";
import { useRouter } from "next/navigation";
import Link from "next/link";

export default function LoginPage() {
  const router = useRouter();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [staffMode, setStaffMode] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setLoading(true);

    try {
      const result = await signIn("credentials", {
        email,
        password,
        redirect: false,
      });

      if (!result || result.error) {
        setError("Invalid email or password.");
        return;
      }

      const session = await getSession();
      const role = String(session?.user?.role ?? "");

      if (staffMode) {
        if (role === "staff" || role === "admin") {
          router.push("/staff");
        } else {
          await signOut({ redirect: false });
          setError("This account is not authorized for staff login.");
          return;
        }
      } else {
        if (role === "resident") {
          router.push("/");
        } else if (role === "staff" || role === "admin") {
          router.push("/staff");
        } else {
          setError("Unable to determine account role. Please sign in again.");
          return;
        }
      }

      router.refresh();
    } catch {
      setError("Unable to sign in. Please try again.");
    } finally {
      setLoading(false);
    }
  }

  function switchMode(isStaff: boolean) {
    setStaffMode(isStaff);
    setError("");
    setEmail("");
    setPassword("");
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-gray-50 px-4">
      <form
        onSubmit={handleSubmit}
        className="w-full max-w-md space-y-5 rounded-xl bg-white p-8 shadow"
      >
        <div>
          <h1 className="text-2xl font-bold text-gray-900">
            Lost & Found
          </h1>
          <p className="mt-1 text-sm text-gray-600">
            {staffMode
              ? "Staff portal sign in"
              : "Sign in to your residential community account"}
          </p>
        </div>

        <div>
          <label
            htmlFor="email"
            className="mb-1 block text-sm font-medium text-gray-900"
          >
            Email
          </label>
          <input
            id="email"
            type="email"
            required
            autoComplete="email"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-gray-900"
          />
        </div>

        <div>
          <label
            htmlFor="password"
            className="mb-1 block text-sm font-medium text-gray-900"
          >
            Password
          </label>
          <input
            id="password"
            type="password"
            required
            autoComplete="current-password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-gray-900"
          />
        </div>

        {error && (
          <p className="text-sm text-red-600" role="alert">
            {error}
          </p>
        )}

        <button
          type="submit"
          disabled={loading}
          className="w-full rounded-md bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700 disabled:opacity-60"
        >
          {loading
            ? "Signing in..."
            : staffMode
              ? "Sign in to staff portal"
              : "Sign in"}
        </button>

        {!staffMode && (
          <p className="text-center text-sm text-gray-600">
            Don&apos;t have a resident account?{" "}
            <Link
              href="/signup"
              className="font-medium text-blue-600 hover:underline"
            >
              Create resident account
            </Link>
          </p>
        )}

        <div className="border-t border-gray-200 pt-4 text-center">
          {staffMode ? (
            <p className="text-sm text-gray-600">
              Not staff?{" "}
              <button
                type="button"
                onClick={() => switchMode(false)}
                className="font-medium text-blue-600 hover:underline"
              >
                Resident sign in
              </button>
            </p>
          ) : (
            <p className="text-sm text-gray-600">
              Are you a staff member?{" "}
              <button
                type="button"
                onClick={() => switchMode(true)}
                className="font-medium text-blue-600 hover:underline"
              >
                Sign in to the staff portal
              </button>
            </p>
          )}
        </div>
      </form>
    </main>
  );
}
