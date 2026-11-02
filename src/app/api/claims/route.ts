
import { NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { auth } from "@/auth";

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
    const [pending, approved, rejected, handovers] =
      await Promise.all([
        pool.query(`
          SELECT *
          FROM public.v_pending_claims
          ORDER BY claim_date DESC;
        `),

        pool.query(`
          SELECT
            c.claim_id,
            c.claim_date,
            c.verification_notes,
            c.lost_report_id,
            c.found_report_id,
            r.name AS claimant_name,
            li.item_name AS lost_item_name,
            fi.item_name AS found_item_name
          FROM public.claim c
          JOIN public.resident r
            ON r.resident_id = c.claimant_id
          JOIN public.lost_report lr
            ON lr.lost_report_id = c.lost_report_id
          JOIN public.item li
            ON li.item_id = lr.item_id
          JOIN public.found_report fr
            ON fr.found_report_id = c.found_report_id
          JOIN public.item fi
            ON fi.item_id = fr.item_id
          WHERE c.status = 'approved'
            AND NOT EXISTS (
              SELECT 1
              FROM public.handover h
              WHERE h.claim_id = c.claim_id
            )
          ORDER BY c.claim_date DESC;
        `),

        pool.query(`
          SELECT
            c.claim_id,
            c.claim_date,
            c.verification_notes,
            r.name AS claimant_name,
            li.item_name AS lost_item_name,
            fi.item_name AS found_item_name,
            s.name AS verified_by_name
          FROM public.claim c
          JOIN public.resident r
            ON r.resident_id = c.claimant_id
          JOIN public.lost_report lr
            ON lr.lost_report_id = c.lost_report_id
          JOIN public.item li
            ON li.item_id = lr.item_id
          JOIN public.found_report fr
            ON fr.found_report_id = c.found_report_id
          JOIN public.item fi
            ON fi.item_id = fr.item_id
          LEFT JOIN public.staff s
            ON s.staff_id = c.verified_by
          WHERE c.status = 'rejected'
          ORDER BY c.claim_date DESC;
        `),

        pool.query(`
          SELECT
            h.handover_id,
            h.claim_id,
            h.handover_date,
            h.verification_method,
            h.remarks,
            s.name AS staff_name,
            r.name AS claimant_name,
            li.item_name AS lost_item_name,
            fi.item_name AS found_item_name
          FROM public.handover h
          JOIN public.staff s
            ON s.staff_id = h.staff_id
          JOIN public.claim c
            ON c.claim_id = h.claim_id
          JOIN public.resident r
            ON r.resident_id = c.claimant_id
          JOIN public.lost_report lr
            ON lr.lost_report_id = c.lost_report_id
          JOIN public.item li
            ON li.item_id = lr.item_id
          JOIN public.found_report fr
            ON fr.found_report_id = c.found_report_id
          JOIN public.item fi
            ON fi.item_id = fr.item_id
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
      {
        success: false,
        message: "Unable to fetch claims.",
      },
      { status: 500 }
    );
  }
}
