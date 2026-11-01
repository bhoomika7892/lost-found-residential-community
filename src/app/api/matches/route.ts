import { NextResponse } from "next/server";
import { pool } from "@/lib/db";

export async function GET() {
  try {
    const result = await pool.query(`
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

      FROM match m
      JOIN lost_report l
        ON l.lost_report_id = m.lost_report_id
      JOIN item li
        ON li.item_id = l.item_id
      JOIN found_report f
        ON f.found_report_id = m.found_report_id
      JOIN item fi
        ON fi.item_id = f.item_id
      JOIN location ll
        ON ll.location_id = l.location_id
      JOIN location fl
        ON fl.location_id = f.location_id

      WHERE l.status IN ('open', 'matched')
        AND f.status IN ('open', 'matched')

      ORDER BY m.match_score DESC, m.generated_at DESC;
    `);

    return NextResponse.json({
      success: true,
      count: result.rows.length,
      matches: result.rows,
    });
  } catch (error) {
    console.error("Fetching matches failed:", error);

    return NextResponse.json(
      { success: false, error: "Failed to fetch matches." },
      { status: 500 }
    );
  }
}