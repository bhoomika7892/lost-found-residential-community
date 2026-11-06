import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { pool } from "@/lib/db";

export const runtime = "nodejs";

type RouteContext = {
  params: Promise<{ id: string }>;
};

// GET /api/lost-items/:id/similar?limit=5
// Semantic (vector) search: open/matched found items ranked by similarity to
// this lost report, via the database function find_similar_found_items().
export async function GET(request: Request, context: RouteContext) {
  const session = await auth();

  if (!session?.user) {
    return NextResponse.json(
      { success: false, message: "Unauthorized" },
      { status: 401 }
    );
  }

  const { id } = await context.params;
  const reportId = Number(id);

  if (!Number.isSafeInteger(reportId) || reportId <= 0) {
    return NextResponse.json(
      { success: false, message: "Invalid report ID" },
      { status: 400 }
    );
  }

  const requestedLimit = Number(new URL(request.url).searchParams.get("limit"));
  const limit =
    Number.isInteger(requestedLimit) && requestedLimit > 0
      ? Math.min(requestedLimit, 20)
      : 5;

  try {
    const report = await pool.query<{ resident_id: number }>(
      "SELECT resident_id FROM lost_report WHERE lost_report_id = $1",
      [reportId]
    );

    if (report.rowCount === 0) {
      return NextResponse.json(
        { success: false, message: "Report not found" },
        { status: 404 }
      );
    }

    // Residents may only search for their own report; staff may search any.
    if (
      session.user.role === "resident" &&
      report.rows[0].resident_id !== Number(session.user.residentId)
    ) {
      return NextResponse.json(
        { success: false, message: "You can only search for your own reports" },
        { status: 403 }
      );
    }

    const result = await pool.query(
      "SELECT * FROM public.find_similar_found_items($1, $2)",
      [reportId, limit]
    );

    return NextResponse.json({
      success: true,
      count: result.rowCount,
      data: result.rows,
    });
  } catch (error) {
    console.error("Similar item search failed:", error);

    return NextResponse.json(
      { success: false, message: "Failed to search for similar items" },
      { status: 500 }
    );
  }
}
