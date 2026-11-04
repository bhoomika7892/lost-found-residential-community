import { NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { auth } from "@/auth";

export async function POST(request: Request) {
  const session = await auth();
  const user = session?.user as
    | { role?: string; residentId?: number }
    | undefined;

  if (!user || user.role !== "resident" || !user.residentId) {
    return NextResponse.json(
      { success: false, message: "Only authenticated residents can submit claims." },
      { status: 401 }
    );
  }

  try {
    const body = await request.json();
    const lostReportId = Number(body.lost_report_id);
    const foundReportId = Number(body.found_report_id);

    if (
      !Number.isSafeInteger(lostReportId) || lostReportId <= 0 ||
      !Number.isSafeInteger(foundReportId) || foundReportId <= 0
    ) {
      return NextResponse.json(
        { success: false, message: "Invalid match selection." },
        { status: 400 }
      );
    }

    const result = await pool.query(
      `
      INSERT INTO public.claim (
        lost_report_id,
        found_report_id,
        claimant_id,
        status
      )
      SELECT
        m.lost_report_id,
        m.found_report_id,
        $3,
        'pending'
      FROM public.match m
      JOIN public.lost_report lr
        ON lr.lost_report_id = m.lost_report_id
      JOIN public.found_report fr
        ON fr.found_report_id = m.found_report_id
      WHERE m.lost_report_id = $1
        AND m.found_report_id = $2
        AND lr.resident_id = $3
        AND lr.status IN ('open', 'matched')
        AND fr.status IN ('open', 'matched')
      ON CONFLICT (lost_report_id, found_report_id) DO NOTHING
      RETURNING claim_id, lost_report_id, found_report_id, status, claim_date;
      `,
      [lostReportId, foundReportId, user.residentId]
    );

    if (result.rows.length === 0) {
      return NextResponse.json(
        {
          success: false,
          message: "This match is unavailable, does not belong to your lost report, or already has a claim.",
        },
        { status: 409 }
      );
    }

    return NextResponse.json(
      {
        success: true,
        message: "Claim submitted successfully. It is awaiting staff verification.",
        claim: result.rows[0],
      },
      { status: 201 }
    );
  } catch (error) {
    console.error("Claim submission failed:", error);
    return NextResponse.json(
      { success: false, message: "Unable to submit claim." },
      { status: 500 }
    );
  }
}

export async function GET() {
  const session = await auth();

  const user = session?.user as
    | { role?: string; staffId?: number }
    | undefined;

  if (
    !user ||
    !["staff", "admin"].includes(user.role ?? "") ||
    !user.staffId
  ) {
    return NextResponse.json(
      { success: false, message: "Unauthorized" },
      { status: 401 }
    );
  }

  try {
    const [pending, approved, rejected, handovers] = await Promise.all([
      pool.query(`
        SELECT *
        FROM public.v_pending_claims
        ORDER BY claim_date DESC;
      `),

      pool.query(`
        SELECT
          c.claim_id, c.claim_date, c.verification_notes,
          c.lost_report_id, c.found_report_id,
          r.name AS claimant_name,
          li.item_name AS lost_item_name,
          fi.item_name AS found_item_name
        FROM public.claim c
        JOIN public.resident r ON r.resident_id = c.claimant_id
        JOIN public.lost_report lr ON lr.lost_report_id = c.lost_report_id
        JOIN public.item li ON li.item_id = lr.item_id
        JOIN public.found_report fr ON fr.found_report_id = c.found_report_id
        JOIN public.item fi ON fi.item_id = fr.item_id
        WHERE c.status = 'approved'
          AND NOT EXISTS (
            SELECT 1 FROM public.handover h WHERE h.claim_id = c.claim_id
          )
        ORDER BY c.claim_date DESC;
      `),

      pool.query(`
        SELECT
          c.claim_id, c.claim_date, c.verification_notes,
          r.name AS claimant_name,
          li.item_name AS lost_item_name,
          fi.item_name AS found_item_name,
          s.name AS verified_by_name
        FROM public.claim c
        JOIN public.resident r ON r.resident_id = c.claimant_id
        JOIN public.lost_report lr ON lr.lost_report_id = c.lost_report_id
        JOIN public.item li ON li.item_id = lr.item_id
        JOIN public.found_report fr ON fr.found_report_id = c.found_report_id
        JOIN public.item fi ON fi.item_id = fr.item_id
        LEFT JOIN public.staff s ON s.staff_id = c.verified_by
        WHERE c.status = 'rejected'
        ORDER BY c.claim_date DESC;
      `),

      pool.query(`
        SELECT
          h.handover_id, h.claim_id, h.handover_date,
          h.verification_method, h.remarks,
          s.name AS staff_name,
          r.name AS claimant_name,
          li.item_name AS lost_item_name,
          fi.item_name AS found_item_name
        FROM public.handover h
        JOIN public.staff s ON s.staff_id = h.staff_id
        JOIN public.claim c ON c.claim_id = h.claim_id
        JOIN public.resident r ON r.resident_id = c.claimant_id
        JOIN public.lost_report lr ON lr.lost_report_id = c.lost_report_id
        JOIN public.item li ON li.item_id = lr.item_id
        JOIN public.found_report fr ON fr.found_report_id = c.found_report_id
        JOIN public.item fi ON fi.item_id = fr.item_id
        ORDER BY h.handover_date DESC;
      `),
    ]);

    return NextResponse.json({
      success: true,
      data: {
        pending: pending.rows,
        approved: approved.rows,
        rejected: rejected.rows,
        handovers: handovers.rows,
      },
    });
  } catch (error) {
    console.error("Fetching claims failed:", error);
    return NextResponse.json(
      { success: false, message: "Unable to fetch claims." },
      { status: 500 }
    );
  }
}
