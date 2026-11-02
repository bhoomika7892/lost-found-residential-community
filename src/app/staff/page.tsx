
"use client";

import { useCallback, useEffect, useState } from "react";
import { signOut } from "next-auth/react";

type Claim = {
  claim_id: number;
  claim_date: string;
  claimant_name: string;
  lost_item_name: string;
  found_item_name: string;
  verification_notes?: string | null;
  verified_by_name?: string | null;
};

type Handover = {
  handover_id: number;
  claim_id: number;
  handover_date: string;
  verification_method: string;
  remarks: string | null;
  staff_name: string;
  claimant_name: string;
  lost_item_name: string;
  found_item_name: string;
};

type DashboardData = {
  pending: Claim[];
  approved: Claim[];
  rejected: Claim[];
  handovers: Handover[];
};

type Tab = "pending" | "approved" | "rejected" | "handovers";

const initialData: DashboardData = {
  pending: [],
  approved: [],
  rejected: [],
  handovers: [],
};

export default function StaffDashboard() {
  const [data, setData] = useState<DashboardData>(initialData);
  const [activeTab, setActiveTab] = useState<Tab>("pending");
  const [loading, setLoading] = useState(true);
  const [busyClaim, setBusyClaim] = useState<number | null>(null);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const [rejectionNotes, setRejectionNotes] = useState<
    Record<number, string>
  >({});

  const [handoverForms, setHandoverForms] = useState<
    Record<number, { method: string; remarks: string }>
  >({});

  const loadClaims = useCallback(async () => {
    setError("");

    try {
      const response = await fetch("/api/claims");
      const result = await response.json();

      if (!response.ok || !result.success) {
        throw new Error(result.message || "Unable to load claims.");
      }

      setData(result.data);
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Unable to load claims."
      );
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadClaims();
  }, [loadClaims]);

  async function approveClaim(claimId: number) {
    if (!window.confirm(`Approve claim #${claimId}?`)) return;

    setBusyClaim(claimId);
    setMessage("");
    setError("");

    try {
      const response = await fetch(`/api/claims/${claimId}/approve`, {
        method: "POST",
      });

      const result = await response.json();

      if (!response.ok || !result.success) {
        throw new Error(result.message || "Claim approval failed.");
      }

      setMessage(`Claim #${claimId} approved successfully.`);
      await loadClaims();
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Claim approval failed."
      );
    } finally {
      setBusyClaim(null);
    }
  }

  async function rejectClaim(claimId: number) {
    const notes = rejectionNotes[claimId]?.trim();

    if (!notes) {
      setError("Enter verification notes before rejecting a claim.");
      return;
    }

    setBusyClaim(claimId);
    setMessage("");
    setError("");

    try {
      const response = await fetch(`/api/claims/${claimId}/reject`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ rejectionNotes: notes }),
      });

      const result = await response.json();

      if (!response.ok || !result.success) {
        throw new Error(result.message || "Claim rejection failed.");
      }

      setMessage(`Claim #${claimId} rejected successfully.`);
      setRejectionNotes((current) => ({
        ...current,
        [claimId]: "",
      }));
      await loadClaims();
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Claim rejection failed."
      );
    } finally {
      setBusyClaim(null);
    }
  }

  async function recordHandover(claimId: number) {
    const form = handoverForms[claimId];

    if (!form?.method) {
      setError("Select a verification method.");
      return;
    }

    setBusyClaim(claimId);
    setMessage("");
    setError("");

    try {
      const response = await fetch(`/api/claims/${claimId}/handover`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          verificationMethod: form.method,
          remarks: form.remarks.trim() || null,
        }),
      });

      const result = await response.json();

      if (!response.ok || !result.success) {
        throw new Error(result.message || "Handover recording failed.");
      }

      setMessage(`Handover for claim #${claimId} recorded successfully.`);
      await loadClaims();
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Handover recording failed."
      );
    } finally {
      setBusyClaim(null);
    }
  }

  const tabs: { id: Tab; label: string; count: number }[] = [
    { id: "pending", label: "Pending Claims", count: data.pending.length },
    { id: "approved", label: "Awaiting Handover", count: data.approved.length },
    { id: "rejected", label: "Rejected", count: data.rejected.length },
    { id: "handovers", label: "Completed Handovers", count: data.handovers.length },
  ];

  return (
    <main className="min-h-screen bg-slate-50 text-slate-900">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-6 py-6">
          <div>
            <p className="text-sm font-semibold uppercase tracking-wider text-teal-700">
              Residential Community
            </p>
            <h1 className="mt-1 text-3xl font-bold">Staff Dashboard</h1>
            <p className="mt-2 text-slate-600">
              Claims verification and item handover management.
            </p>
          </div>

          <button
            onClick={() => signOut({ callbackUrl: "/login" })}
            className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-semibold hover:bg-slate-100"
          >
            Logout
          </button>
        </div>
      </header>

      <section className="mx-auto max-w-6xl px-6 py-10">
        <div className="grid gap-4 sm:grid-cols-4">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className="rounded-xl border border-slate-200 bg-white p-5 text-left shadow-sm hover:border-teal-500"
            >
              <p className="text-sm text-slate-500">{tab.label}</p>
              <p className="mt-2 text-3xl font-bold">{tab.count}</p>
            </button>
          ))}
        </div>

        {message && (
          <p className="mt-6 rounded-lg bg-emerald-50 p-4 text-sm text-emerald-700">
            {message}
          </p>
        )}

        {error && (
          <p className="mt-6 rounded-lg bg-red-50 p-4 text-sm text-red-700">
            {error}
          </p>
        )}

        <div className="mt-8 flex flex-wrap gap-2 border-b border-slate-200">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`rounded-t-lg px-4 py-3 text-sm font-semibold ${
                activeTab === tab.id
                  ? "border-b-2 border-teal-600 text-teal-700"
                  : "text-slate-600 hover:bg-white"
              }`}
            >
              {tab.label} ({tab.count})
            </button>
          ))}
        </div>

        {loading ? (
          <p className="mt-6 rounded-xl bg-white p-6">Loading claims...</p>
        ) : (
          <div className="mt-6 space-y-5">
            {activeTab === "pending" &&
              (data.pending.length === 0 ? (
                <EmptyMessage message="There are no pending claims to review." />
              ) : (
                data.pending.map((claim) => (
                  <article key={claim.claim_id} className="rounded-2xl border bg-white p-6 shadow-sm">
                    <ClaimDetails claim={claim} />

                    <label className="mt-5 block text-sm font-medium">
                      Verification / rejection notes
                      <textarea
                        rows={3}
                        value={rejectionNotes[claim.claim_id] || ""}
                        onChange={(event) =>
                          setRejectionNotes((current) => ({
                            ...current,
                            [claim.claim_id]: event.target.value,
                          }))
                        }
                        placeholder="Enter notes if rejecting this claim."
                        className="mt-2 w-full rounded-lg border border-slate-300 p-3 font-normal"
                      />
                    </label>

                    <div className="mt-4 flex flex-wrap gap-3">
                      <button
                        disabled={busyClaim === claim.claim_id}
                        onClick={() => approveClaim(claim.claim_id)}
                        className="rounded-lg bg-teal-700 px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
                      >
                        Approve Claim
                      </button>

                      <button
                        disabled={busyClaim === claim.claim_id}
                        onClick={() => rejectClaim(claim.claim_id)}
                        className="rounded-lg bg-red-700 px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
                      >
                        Reject Claim
                      </button>
                    </div>
                  </article>
                ))
              ))}

            {activeTab === "approved" &&
              (data.approved.length === 0 ? (
                <EmptyMessage message="There are no approved claims awaiting handover." />
              ) : (
                data.approved.map((claim) => (
                  <article key={claim.claim_id} className="rounded-2xl border bg-white p-6 shadow-sm">
                    <ClaimDetails claim={claim} />

                    <div className="mt-5 grid gap-4 sm:grid-cols-2">
                      <label className="block text-sm font-medium">
                        Verification method
                        <select
                          value={handoverForms[claim.claim_id]?.method || ""}
                          onChange={(event) =>
                            setHandoverForms((current) => ({
                              ...current,
                              [claim.claim_id]: {
                                method: event.target.value,
                                remarks: current[claim.claim_id]?.remarks || "",
                              },
                            }))
                          }
                          className="mt-2 w-full rounded-lg border border-slate-300 p-3 font-normal"
                        >
                          <option value="">Select method</option>
                          <option value="photo_id">Photo ID</option>
                          <option value="resident_id">Resident ID</option>
                          <option value="security_question">Security Question</option>
                          <option value="other">Other</option>
                        </select>
                      </label>

                      <label className="block text-sm font-medium">
                        Handover remarks
                        <input
                          value={handoverForms[claim.claim_id]?.remarks || ""}
                          onChange={(event) =>
                            setHandoverForms((current) => ({
                              ...current,
                              [claim.claim_id]: {
                                method: current[claim.claim_id]?.method || "",
                                remarks: event.target.value,
                              },
                            }))
                          }
                          placeholder="Optional remarks"
                          className="mt-2 w-full rounded-lg border border-slate-300 p-3 font-normal"
                        />
                      </label>
                    </div>

                    <button
                      disabled={busyClaim === claim.claim_id}
                      onClick={() => recordHandover(claim.claim_id)}
                      className="mt-4 rounded-lg bg-indigo-700 px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
                    >
                      Record Handover
                    </button>
                  </article>
                ))
              ))}

            {activeTab === "rejected" &&
              (data.rejected.length === 0 ? (
                <EmptyMessage message="There are no rejected claims." />
              ) : (
                data.rejected.map((claim) => (
                  <article key={claim.claim_id} className="rounded-2xl border bg-white p-6 shadow-sm">
                    <ClaimDetails claim={claim} />
                    <p className="mt-4 text-sm text-red-700">
                      <strong>Rejection notes:</strong>{" "}
                      {claim.verification_notes}
                    </p>
                    <p className="mt-2 text-sm text-slate-500">
                      Reviewed by: {claim.verified_by_name || "—"}
                    </p>
                  </article>
                ))
              ))}

            {activeTab === "handovers" &&
              (data.handovers.length === 0 ? (
                <EmptyMessage message="No completed handovers yet." />
              ) : (
                data.handovers.map((handover) => (
                  <article key={handover.handover_id} className="rounded-2xl border bg-white p-6 shadow-sm">
                    <h2 className="text-lg font-semibold">
                      Handover #{handover.handover_id} · Claim #{handover.claim_id}
                    </h2>
                    <p className="mt-3 text-sm text-slate-600">
                      Claimant: {handover.claimant_name}
                    </p>
                    <p className="mt-2 text-sm text-slate-600">
                      Lost item: {handover.lost_item_name}
                    </p>
                    <p className="mt-2 text-sm text-slate-600">
                      Found item: {handover.found_item_name}
                    </p>
                    <p className="mt-2 text-sm text-slate-600">
                      Verification: {handover.verification_method}
                    </p>
                    <p className="mt-2 text-sm text-slate-600">
                      Remarks: {handover.remarks || "—"}
                    </p>
                    <p className="mt-2 text-sm text-slate-600">
                      Recorded by: {handover.staff_name}
                    </p>
                    <p className="mt-2 text-sm text-slate-500">
                      Date: {new Date(handover.handover_date).toLocaleString("en-IN")}
                    </p>
                  </article>
                ))
              ))}
          </div>
        )}
      </section>
    </main>
  );
}

function ClaimDetails({ claim }: { claim: Claim }) {
  return (
    <>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-lg font-semibold">Claim #{claim.claim_id}</h2>
        <span className="rounded-full bg-amber-50 px-3 py-1 text-xs font-semibold text-amber-800">
          Submitted {new Date(claim.claim_date).toLocaleDateString("en-IN")}
        </span>
      </div>

      <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <div className="rounded-xl bg-slate-50 p-4">
          <p className="text-xs font-semibold uppercase text-slate-500">Lost item</p>
          <p className="mt-2 font-semibold">{claim.lost_item_name}</p>
        </div>

        <div className="rounded-xl bg-slate-50 p-4">
          <p className="text-xs font-semibold uppercase text-slate-500">Found item</p>
          <p className="mt-2 font-semibold">{claim.found_item_name}</p>
        </div>
      </div>

      <p className="mt-4 text-sm text-slate-600">
        Claimant: <strong>{claim.claimant_name}</strong>
      </p>

      {claim.verification_notes && (
        <p className="mt-2 text-sm text-slate-600">
          Notes: {claim.verification_notes}
        </p>
      )}
    </>
  );
}

function EmptyMessage({ message }: { message: string }) {
  return (
    <p className="rounded-xl border border-slate-200 bg-white p-6 text-slate-600">
      {message}
    </p>
  );
}
