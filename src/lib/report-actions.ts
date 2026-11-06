import { after, NextResponse } from "next/server";
import { auth } from "@/auth";
import { pool } from "@/lib/db";
import { processNewItem } from "@/lib/process-new-item";

type ReportKind = "lost" | "found";

// Fixed lookup table: these strings are never built from user input.
const CONFIG = {
  lost: {
    table: "lost_report",
    idColumn: "lost_report_id",
    withdrawFunction: "withdraw_lost_report",
  },
  found: {
    table: "found_report",
    idColumn: "found_report_id",
    withdrawFunction: "withdraw_found_report",
  },
} as const;

const EDITABLE_FIELDS = ["item_name", "color", "brand", "description"] as const;

type RouteContext = {
  params: Promise<{ id: string }>;
};

function reply(success: boolean, message: string, status: number) {
  return NextResponse.json({ success, message }, { status });
}

async function getResidentId(): Promise<number | null> {
  const session = await auth();

  if (
    !session?.user ||
    session.user.role !== "resident" ||
    !session.user.residentId
  ) {
    return null;
  }

  const residentId = Number(session.user.residentId);

  return Number.isSafeInteger(residentId) && residentId > 0
    ? residentId
    : null;
}

async function getReportId(context: RouteContext): Promise<number | null> {
  const { id } = await context.params;
  const reportId = Number(id);

  return Number.isSafeInteger(reportId) && reportId > 0 ? reportId : null;
}

/**
 * Builds the PATCH (edit) and DELETE (withdraw) handlers for one kind of
 * report. A resident may only change their own report, and only while it is
 * still open or matched.
 *
 * PATCH  -> UPDATE item. The database trigger trg_item_text_changed clears the
 *           stale embedding and its derived matches; the embedding is then
 *           regenerated in the background.
 * DELETE -> calls withdraw_lost_report / withdraw_found_report, which removes
 *           the report, its matches and its embedding.
 */
export function makeReportHandlers(kind: ReportKind) {
  const config = CONFIG[kind];

  async function PATCH(request: Request, context: RouteContext) {
    const residentId = await getResidentId();

    if (!residentId) {
      return reply(false, "Unauthorized", 401);
    }

    const reportId = await getReportId(context);

    if (!reportId) {
      return reply(false, "Invalid report ID", 400);
    }

    let body: Record<string, unknown>;

    try {
      body = await request.json();
    } catch {
      return reply(false, "Request body must be valid JSON", 400);
    }

    const updates: { column: string; value: string | null }[] = [];

    for (const field of EDITABLE_FIELDS) {
      if (!(field in body)) {
        continue;
      }

      const raw = body[field];

      if (field === "item_name") {
        if (typeof raw !== "string" || raw.trim() === "") {
          return reply(false, "Item name cannot be empty", 400);
        }

        if (raw.trim().length > 100) {
          return reply(false, "Item name must be 100 characters or fewer", 400);
        }

        updates.push({ column: field, value: raw.trim() });
      } else {
        updates.push({
          column: field,
          value: typeof raw === "string" && raw.trim() !== "" ? raw.trim() : null,
        });
      }
    }

    if (updates.length === 0) {
      return reply(false, "Nothing to update", 400);
    }

    const client = await pool.connect();
    let itemId = 0;

    try {
      await client.query("BEGIN");

      const report = await client.query(
        `
          SELECT item_id, resident_id, status
          FROM ${config.table}
          WHERE ${config.idColumn} = $1
          FOR UPDATE
        `,
        [reportId]
      );

      const row = report.rows[0];

      if (!row) {
        await client.query("ROLLBACK");
        return reply(false, "Report not found", 404);
      }

      if (row.resident_id !== residentId) {
        await client.query("ROLLBACK");
        return reply(false, "You can only edit your own reports", 403);
      }

      if (!["open", "matched"].includes(row.status)) {
        await client.query("ROLLBACK");
        return reply(
          false,
          `Only open or matched reports can be edited (current status: ${row.status})`,
          409
        );
      }

      itemId = Number(row.item_id);

      // Column names come from the fixed EDITABLE_FIELDS list above.
      const setClause = updates
        .map((update, index) => `${update.column} = $${index + 2}`)
        .join(", ");

      await client.query(`UPDATE item SET ${setClause} WHERE item_id = $1`, [
        itemId,
        ...updates.map((update) => update.value),
      ]);

      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      console.error(`Updating ${kind} report failed:`, error);
      return reply(false, "Failed to update report", 500);
    } finally {
      client.release();
    }

    // Respond now; refill the embedding and matches after the response.
    after(async () => {
      try {
        await processNewItem(itemId);
      } catch (error) {
        console.error("Report updated, but re-matching failed:", error);
      }
    });

    return reply(
      true,
      "Report updated. Suggested matches will refresh shortly.",
      200
    );
  }

  async function DELETE(_request: Request, context: RouteContext) {
    const residentId = await getResidentId();

    if (!residentId) {
      return reply(false, "Unauthorized", 401);
    }

    const reportId = await getReportId(context);

    if (!reportId) {
      return reply(false, "Invalid report ID", 400);
    }

    try {
      const result = await pool.query<{ result: string }>(
        `SELECT public.${config.withdrawFunction}($1, $2) AS result`,
        [reportId, residentId]
      );

      return reply(true, result.rows[0].result, 200);
    } catch (error) {
      const pgError = error as { code?: string; message?: string };

      // P0001 = our own RAISE EXCEPTION messages: safe to show to the user.
      if (pgError.code === "P0001" && pgError.message) {
        return reply(false, pgError.message, 409);
      }

      console.error(`Withdrawing ${kind} report failed:`, error);
      return reply(false, "Failed to withdraw report", 500);
    }
  }

  return { PATCH, DELETE };
}
