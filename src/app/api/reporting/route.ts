export const runtime = "nodejs";

import { NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { auth } from "@/auth";

export async function GET() {
  const session = await auth();

  if (!session?.user) {
    return NextResponse.json(
      { success: false, message: "Unauthorized" },
      { status: 401 }
    );
  }

  try {
    const [summaryResult, categoryResult] = await Promise.all([
      pool.query(`
        SELECT
          (SELECT COUNT(*) FROM lost_report) AS total_lost_reports,
          (SELECT COUNT(*) FROM found_report) AS total_found_reports,
          (SELECT COUNT(*) FROM lost_report WHERE status = 'open')
            AS open_lost_reports,
          (SELECT COUNT(*) FROM found_report WHERE status = 'open')
            AS open_found_reports,
          (SELECT COUNT(*) FROM match) AS total_matches;
      `),

      pool.query(`
        SELECT
          c.category_name,
          COUNT(*) AS report_count
        FROM (
          SELECT item_id FROM lost_report
          UNION ALL
          SELECT item_id FROM found_report
        ) reports
        JOIN item i ON i.item_id = reports.item_id
        JOIN category c ON c.category_id = i.category_id
        GROUP BY c.category_name
        ORDER BY report_count DESC, c.category_name;
      `),
    ]);

    return NextResponse.json({
      success: true,
      summary: summaryResult.rows[0],
      reportsByCategory: categoryResult.rows,
    });
  } catch (error) {
    console.error("Fetching reporting analytics failed:", error);

    return NextResponse.json(
      { success: false, message: "Failed to fetch reporting analytics" },
      { status: 500 }
    );
  }
}