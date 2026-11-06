import { makeReportHandlers } from "@/lib/report-actions";

export const runtime = "nodejs";

// PATCH  /api/lost-items/:id  -> edit your own lost report (re-embeds the item)
// DELETE /api/lost-items/:id  -> withdraw your own lost report
export const { PATCH, DELETE } = makeReportHandlers("lost");
