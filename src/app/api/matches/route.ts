
import { NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { auth } from "@/auth";

export async function GET() {
  const session = await auth();
  console.log("MATCHES SESSION:", session?.user);
  const user = session?.user as
    | { role?: string; residentId?: number }
    | undefined;

  if (
    !user ||
    user.role !== "resident" ||
    !user.residentId
  ) {
    return NextResponse.json(
      { success: false, message: "Only authenticated residents can view their matches." },
      { status: 401 }
    );
  }

  try {
    const result = await pool.query(
      `
      SELECT
        m.match_id,
        m.lost_report_id,
        m.found_report_id,
        m.similarity_score,
        m.match_score,
        m.generated_at,

        li.item_name AS lost_item_name,
        li.color AS lost_color,
        li.brand AS lost_brand,
        li.description AS lost_description,

        fi.item_name AS found_item_name,
        fi.color AS found_color,
        fi.brand AS found_brand,
        fi.description AS found_description,

        l.lost_date,
        f.found_date,

        ll.location_name AS lost_location,
        fl.location_name AS found_location

      FROM public.match m
      JOIN public.lost_report l
        ON l.lost_report_id = m.lost_report_id
      JOIN public.item li
        ON li.item_id = l.item_id
      JOIN public.found_report f
        ON f.found_report_id = m.found_report_id
      JOIN public.item fi
        ON fi.item_id = f.item_id
      JOIN public.location ll
        ON ll.location_id = l.location_id
      JOIN public.location fl
        ON fl.location_id = f.location_id

      WHERE l.resident_id = $1
        AND l.status IN ('open', 'matched')
        AND f.status IN ('open', 'matched')

      ORDER BY m.match_score DESC, m.generated_at DESC;
      `,
      [user.residentId]
    );

    return NextResponse.json({
      success: true,
      count: result.rows.length,
      matches: result.rows,
    });
  } catch (error) {
    console.error("Fetching resident matches failed:", error);

    return NextResponse.json(
      { success: false, message: "Failed to fetch matches." },
      { status: 500 }
    );
  }
}
