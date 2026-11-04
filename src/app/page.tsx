"use client";

import { useEffect, useState, type FormEvent } from "react";
import { signOut } from "next-auth/react";
type ItemReport = {
  lost_report_id?: number;
  found_report_id?: number;
  item_id: number;
  item_name: string;
  color: string | null;
  brand: string | null;
  description: string | null;
  category_name: string;
  location_name: string;
  location_type: string;
  lost_date?: string;
  found_date?: string;
  reported_date: string;
  status: string;
};

type Match = {
  match_id: number;
  lost_report_id: number;
  found_report_id: number;
  lost_item_name: string;
  found_item_name: string;
  lost_color: string | null;
  found_color: string | null;
  lost_brand: string | null;
  found_brand: string | null;
  lost_description: string | null;
  found_description: string | null;
  lost_date: string;
  found_date: string;
  lost_location: string;
  found_location: string;
  similarity_score: string;
  match_score: string;
};

type Tab = "found" | "lost" | "matches";
type ReportType = "lost" | "found";

type ReportFormData = {
  item_name: string;
  category_id: string;
  color: string;
  brand: string;
  description: string;
  location_id: string;
  report_date: string;
};

const categories = [
  { id: "1", name: "Wallets & Bags" },
  { id: "2", name: "Electronics" },
  { id: "3", name: "Keys" },
  { id: "4", name: "Clothing & Accessories" },
  { id: "5", name: "Documents & Cards" },
  { id: "6", name: "Others" },
];

const locations = [
  { id: "1", name: "Block A Lobby" },
  { id: "2", name: "Block A Lift 2" },
  { id: "3", name: "Block B Parking" },
  { id: "4", name: "Block C Lobby" },
  { id: "5", name: "Central Garden" },
  { id: "6", name: "Clubhouse" },
  { id: "7", name: "Gymnasium" },
  { id: "8", name: "Main Gate" },
];

function getTodayDate() {
  const now = new Date();
  const localDate = new Date(now.getTime() - now.getTimezoneOffset() * 60000);
  return localDate.toISOString().slice(0, 10);
}

function createEmptyForm(): ReportFormData {
  return {
    item_name: "",
    category_id: "",
    color: "",
    brand: "",
    description: "",
    location_id: "",
    report_date: getTodayDate(),
  };
}

export default function Home() {
  const [activeTab, setActiveTab] = useState<Tab>("found");
  const [foundItems, setFoundItems] = useState<ItemReport[]>([]);
  const [lostItems, setLostItems] = useState<ItemReport[]>([]);
  const [matches, setMatches] = useState<Match[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const [activeForm, setActiveForm] = useState<ReportType | null>(null);
  const [formData, setFormData] = useState<ReportFormData>(createEmptyForm);
  const [submitting, setSubmitting] = useState(false);
  const [formMessage, setFormMessage] = useState("");
  const [formError, setFormError] = useState("");

  async function loadDashboard() {
    const [foundResponse, lostResponse, matchResponse] = await Promise.all([
      fetch("/api/found-items"),
      fetch("/api/lost-items"),
      fetch("/api/matches"),
    ]);

    const [foundResult, lostResult, matchResult] = await Promise.all([
      foundResponse.json(),
      lostResponse.json(),
      matchResponse.json(),
    ]);

    if (
      !foundResponse.ok ||
      !lostResponse.ok ||
      !matchResponse.ok ||
      !foundResult.success ||
      !lostResult.success ||
      !matchResult.success
    ) {
      throw new Error("Unable to load dashboard data");
    }

    setFoundItems(foundResult.data);
    setLostItems(lostResult.data);
    setMatches(matchResult.matches);
  }

  useEffect(() => {
    async function initializeDashboard() {
      try {
        await loadDashboard();
      } catch {
        setError("Unable to load dashboard data. Please try again.");
      } finally {
        setLoading(false);
      }
    }

    initializeDashboard();
  }, []);

  function openReportForm(type: ReportType) {
    setActiveForm((current) => (current === type ? null : type));
    setFormData(createEmptyForm());
    setFormMessage("");
    setFormError("");
  }

  async function handleReportSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!activeForm) return;

    setSubmitting(true);
    setFormMessage("");
    setFormError("");

    const endpoint =
      activeForm === "lost" ? "/api/lost-items" : "/api/found-items";

    const payload = {
      item_name: formData.item_name.trim(),
      category_id: Number(formData.category_id),
      color: formData.color.trim() || null,
      brand: formData.brand.trim() || null,
      description: formData.description.trim() || null,
      location_id: Number(formData.location_id),
      [activeForm === "lost" ? "lost_date" : "found_date"]:
        formData.report_date,
    };

    try {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });

      const result = await response.json();

      if (!response.ok || !result.success) {
        throw new Error(result.message || "Unable to submit report.");
      }

      await loadDashboard();

      setFormMessage(
        activeForm === "lost"
          ? "Lost item reported successfully."
          : "Found item reported successfully."
      );

      setFormData(createEmptyForm());
      setActiveForm(null);
    } catch (err) {
      setFormError(
        err instanceof Error
          ? err.message
          : "Something went wrong while submitting the report."
      );
    } finally {
      setSubmitting(false);
    }
  }

  const tabs: { id: Tab; label: string; count: number }[] = [
    { id: "found", label: "Found Items", count: foundItems.length },
    { id: "lost", label: "Lost Items", count: lostItems.length },
    { id: "matches", label: "Potential Matches", count: matches.length },
  ];

  return (
    <main className="min-h-screen bg-slate-50 text-slate-900">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-6 py-6">
          <div>
            <p className="text-sm font-semibold uppercase tracking-wider text-teal-700">
              Residential Community
            </p>
            <h1 className="mt-1 text-3xl font-bold">Lost & Found</h1>
            <p className="mt-2 text-slate-600">
              Helping residents reconnect with their belongings.
            </p>
          </div>

          <button
            type="button"
            onClick={() => signOut({ callbackUrl: "/login" })}
            className="shrink-0 rounded-lg border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-700 transition hover:bg-slate-100"
          >
            Logout
          </button>
        </div>
      </header>

      <section className="mx-auto max-w-6xl px-6 py-10">
        {/* Dashboard summary cards */}
        <div className="grid gap-4 sm:grid-cols-3">
          <SummaryCard label="Open Lost Reports" value={lostItems.length} />
          <SummaryCard label="Open Found Reports" value={foundItems.length} />
          <SummaryCard label="Potential Matches" value={matches.length} />
        </div>

        {/* Report submission section */}
        <div className="mt-8 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <div>
            <h2 className="text-xl font-semibold">Report an Item</h2>
            <p className="mt-1 text-sm text-slate-600">
              Report an item you lost or found in the residential community.
            </p>
          </div>

          <div className="mt-4 flex flex-wrap gap-3">
            <button
              type="button"
              onClick={() => openReportForm("lost")}
              className="rounded-lg bg-teal-700 px-5 py-3 text-sm font-semibold text-white transition hover:bg-teal-800"
            >
              Report Lost Item
            </button>

            <button
              type="button"
              onClick={() => openReportForm("found")}
              className="rounded-lg bg-indigo-700 px-5 py-3 text-sm font-semibold text-white transition hover:bg-indigo-800"
            >
              Report Found Item
            </button>
          </div>

          {formMessage && (
            <p className="mt-4 rounded-lg bg-emerald-50 p-3 text-sm text-emerald-700">
              {formMessage}
            </p>
          )}

          {formError && (
            <p className="mt-4 rounded-lg bg-red-50 p-3 text-sm text-red-700">
              {formError}
            </p>
          )}

          {activeForm && (
            <form onSubmit={handleReportSubmit} className="mt-6 space-y-4">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <h3 className="text-lg font-semibold">
                  {activeForm === "lost"
                    ? "Report a Lost Item"
                    : "Report a Found Item"}
                </h3>
                <button
                  type="button"
                  onClick={() => setActiveForm(null)}
                  className="text-sm font-medium text-slate-500 hover:text-slate-800"
                >
                  Close
                </button>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <label className="block text-sm font-medium">
                  Item name *
                  <input
                    required
                    maxLength={100}
                    value={formData.item_name}
                    onChange={(event) =>
                      setFormData({
                        ...formData,
                        item_name: event.target.value,
                      })
                    }
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 font-normal"
                    placeholder="e.g. Black backpack"
                  />
                </label>

                <label className="block text-sm font-medium">
                  Category *
                  <select
                    required
                    value={formData.category_id}
                    onChange={(event) =>
                      setFormData({
                        ...formData,
                        category_id: event.target.value,
                      })
                    }
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 font-normal"
                  >
                    <option value="">Select category</option>
                    {categories.map((category) => (
                      <option key={category.id} value={category.id}>
                        {category.name}
                      </option>
                    ))}
                  </select>
                </label>

                <label className="block text-sm font-medium">
                  Color
                  <input
                    maxLength={40}
                    value={formData.color}
                    onChange={(event) =>
                      setFormData({
                        ...formData,
                        color: event.target.value,
                      })
                    }
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 font-normal"
                    placeholder="e.g. Black"
                  />
                </label>

                <label className="block text-sm font-medium">
                  Brand
                  <input
                    maxLength={60}
                    value={formData.brand}
                    onChange={(event) =>
                      setFormData({
                        ...formData,
                        brand: event.target.value,
                      })
                    }
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 font-normal"
                    placeholder="e.g. Samsung"
                  />
                </label>

                <label className="block text-sm font-medium">
                  Location *
                  <select
                    required
                    value={formData.location_id}
                    onChange={(event) =>
                      setFormData({
                        ...formData,
                        location_id: event.target.value,
                      })
                    }
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 font-normal"
                  >
                    <option value="">Select location</option>
                    {locations.map((location) => (
                      <option key={location.id} value={location.id}>
                        {location.name}
                      </option>
                    ))}
                  </select>
                </label>

                <label className="block text-sm font-medium">
                  {activeForm === "lost" ? "Date lost *" : "Date found *"}
                  <input
                    required
                    type="date"
                    max={getTodayDate()}
                    value={formData.report_date}
                    onChange={(event) =>
                      setFormData({
                        ...formData,
                        report_date: event.target.value,
                      })
                    }
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 font-normal"
                  />
                </label>
              </div>

              <label className="block text-sm font-medium">
                Description
                <textarea
                  rows={3}
                  value={formData.description}
                  onChange={(event) =>
                    setFormData({
                      ...formData,
                      description: event.target.value,
                    })
                  }
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 font-normal"
                  placeholder="Add details that may help identify the item."
                />
              </label>

              <div className="flex flex-wrap gap-3">
                <button
                  type="submit"
                  disabled={submitting}
                  className="rounded-lg bg-teal-700 px-5 py-2.5 text-sm font-semibold text-white transition hover:bg-teal-800 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {submitting ? "Submitting..." : "Submit Report"}
                </button>

                <button
                  type="button"
                  disabled={submitting}
                  onClick={() => {
                    setActiveForm(null);
                    setFormError("");
                  }}
                  className="rounded-lg border border-slate-300 px-5 py-2.5 text-sm font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                >
                  Cancel
                </button>
              </div>
            </form>
          )}
        </div>

        {/* Existing dashboard tabs */}
        <div className="mt-10 border-b border-slate-200">
          <nav
            className="flex flex-wrap gap-2"
            aria-label="Dashboard sections"
          >
            {tabs.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={`rounded-t-lg px-4 py-3 text-sm font-semibold transition ${
                  activeTab === tab.id
                    ? "border-b-2 border-teal-600 bg-white text-teal-700"
                    : "text-slate-600 hover:bg-white hover:text-slate-900"
                }`}
              >
                {tab.label}
                <span className="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-xs">
                  {tab.count}
                </span>
              </button>
            ))}
          </nav>
        </div>

        <div className="pt-6">
          {loading && (
            <p className="rounded-xl bg-white p-6 text-slate-600 shadow-sm">
              Loading dashboard...
            </p>
          )}

          {error && (
            <p className="rounded-xl bg-red-50 p-6 text-red-700">{error}</p>
          )}

          {!loading && !error && activeTab === "found" && (
            <ItemGrid
              items={foundItems}
              type="found"
              emptyMessage="No open found-item reports at the moment."
            />
          )}

          {!loading && !error && activeTab === "lost" && (
            <ItemGrid
              items={lostItems}
              type="lost"
              emptyMessage="No open lost-item reports at the moment."
            />
          )}

          {!loading && !error && activeTab === "matches" && (
            <MatchGrid matches={matches} />
          )}
        </div>
      </section>

      <footer className="border-t border-slate-200 bg-white">
        <div className="mx-auto max-w-6xl px-6 py-5 text-sm text-slate-500">
          Lost & Found Â· Residential Community
        </div>
      </footer>
    </main>
  );
}

function SummaryCard({
  label,
  value,
}: {
  label: string;
  value: number;
}) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <p className="text-sm text-slate-500">{label}</p>
      <p className="mt-2 text-3xl font-bold text-slate-900">{value}</p>
    </div>
  );
}

function ItemGrid({
  items,
  type,
  emptyMessage,
}: {
  items: ItemReport[];
  type: "lost" | "found";
  emptyMessage: string;
}) {
  if (items.length === 0) {
    return (
      <p className="rounded-xl bg-white p-6 text-slate-600 shadow-sm">
        {emptyMessage}
      </p>
    );
  }

  return (
    <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
      {items.map((item) => {
        const reportId =
          type === "lost" ? item.lost_report_id : item.found_report_id;
        const date = type === "lost" ? item.lost_date : item.found_date;

        return (
          <article
            key={reportId}
            className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"
          >
            <div className="flex items-start justify-between gap-3">
              <span className="rounded-full bg-teal-50 px-3 py-1 text-xs font-semibold text-teal-700">
                {item.category_name}
              </span>
              <span className="rounded-full bg-emerald-50 px-3 py-1 text-xs font-medium text-emerald-700">
                Open
              </span>
            </div>

            <h3 className="mt-4 text-xl font-semibold">{item.item_name}</h3>
            <p className="mt-2 min-h-12 text-sm leading-6 text-slate-600">
              {item.description || "No description provided."}
            </p>

            <dl className="mt-4 space-y-2 border-t border-slate-100 pt-4 text-sm">
              {(item.color || item.brand) && (
                <div className="flex gap-2">
                  <dt className="font-medium text-slate-500">Details:</dt>
                  <dd>{[item.color, item.brand].filter(Boolean).join(" Â· ")}</dd>
                </div>
              )}

              <div className="flex gap-2">
                <dt className="font-medium text-slate-500">Location:</dt>
                <dd>{item.location_name}</dd>
              </div>

              <div className="flex gap-2">
                <dt className="font-medium text-slate-500">
                  {type === "lost" ? "Lost on:" : "Found on:"}
                </dt>
                <dd>
                  {date ? new Date(date).toLocaleDateString("en-IN") : "â€”"}
                </dd>
              </div>
            </dl>
          </article>
        );
      })}
    </div>
  );
}

function MatchGrid({ matches }: { matches: Match[] }) {
  const [claimingId, setClaimingId] = useState<number | null>(null);
  const [messages, setMessages] = useState<Record<number, string>>({});
  const [claimedIds, setClaimedIds] = useState<number[]>([]);

  async function submitClaim(match: Match) {
    setClaimingId(match.match_id);
    setMessages((current) => ({ ...current, [match.match_id]: "" }));

    try {
      const response = await fetch("/api/claims", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          lost_report_id: match.lost_report_id,
          found_report_id: match.found_report_id,
        }),
      });

      const result = await response.json();

      if (!response.ok || !result.success) {
        throw new Error(result.message || "Unable to submit claim.");
      }

      setClaimedIds((current) => [...current, match.match_id]);
      setMessages((current) => ({
        ...current,
        [match.match_id]: "Claim submitted. Awaiting staff verification.",
      }));
    } catch (error) {
      setMessages((current) => ({
        ...current,
        [match.match_id]:
          error instanceof Error ? error.message : "Unable to submit claim.",
      }));
    } finally {
      setClaimingId(null);
    }
  }

  if (matches.length === 0) {
    return (
      <p className="rounded-xl bg-white p-6 text-slate-600 shadow-sm">
        No potential matches are available yet.
      </p>
    );
  }

  return (
    <div className="grid gap-5 lg:grid-cols-2">
      {matches.map((match) => (
        <article
          key={match.match_id}
          className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"
        >
          <div className="flex flex-wrap items-center justify-between gap-3">
            <span className="rounded-full bg-amber-50 px-3 py-1 text-xs font-semibold text-amber-800">
              Potential Match
            </span>
            <span className="text-lg font-bold text-teal-700">
              {Number(match.match_score).toFixed(2)}% match
            </span>
          </div>

          <div className="mt-5 grid gap-4 sm:grid-cols-2">
            <MatchItem
              label="Lost Item"
              name={match.lost_item_name}
              color={match.lost_color}
              brand={match.lost_brand}
              description={match.lost_description}
              location={match.lost_location}
            />
            <MatchItem
              label="Found Item"
              name={match.found_item_name}
              color={match.found_color}
              brand={match.found_brand}
              description={match.found_description}
              location={match.found_location}
            />
          </div>

          <p className="mt-4 text-xs text-slate-500">
            Semantic similarity: {(Number(match.similarity_score) * 100).toFixed(2)}%
          </p>

          <button
            type="button"
            onClick={() => submitClaim(match)}
            disabled={claimingId !== null || claimedIds.includes(match.match_id)}
            className="mt-4 rounded-lg bg-teal-700 px-4 py-2 text-sm font-semibold text-white hover:bg-teal-800 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {claimingId === match.match_id
              ? "Submitting..."
              : claimedIds.includes(match.match_id)
                ? "Claim Submitted"
                : "Claim This Item"}
          </button>

          {messages[match.match_id] && (
            <p className="mt-2 text-sm text-slate-600" role="status">
              {messages[match.match_id]}
            </p>
          )}
        </article>
      ))}
    </div>
  );
}
function MatchItem({
  label,
  name,
  color,
  brand,
  description,
  location,
}: {
  label: string;
  name: string;
  color: string | null;
  brand: string | null;
  description: string | null;
  location: string;
}) {
  return (
    <div className="rounded-xl bg-slate-50 p-4">
      <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        {label}
      </p>
      <h3 className="mt-2 font-semibold">{name}</h3>
      <p className="mt-2 text-sm text-slate-600">
        {description || "No description provided."}
      </p>
      <p className="mt-3 text-xs text-slate-500">
        {[color, brand].filter(Boolean).join(" Â· ") || "No additional details"}
      </p>
      <p className="mt-1 text-xs text-slate-500">Location: {location}</p>
    </div>
  );
}
