import { makeReportHandlers } from "@/lib/report-actions";

export const runtime = "nodejs";

// PATCH  /api/found-items/:id  -> edit your own found report (re-embeds the item)
// DELETE /api/found-items/:id  -> withdraw your own found report
export const { PATCH, DELETE } = makeReportHandlers("found");
