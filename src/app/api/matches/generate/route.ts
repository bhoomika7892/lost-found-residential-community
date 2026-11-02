import { NextResponse } from "next/server";
import { pool } from "@/lib/db";

export async function POST() {
  try {
    const result = await pool.query(`
      WITH candidate_matches AS (
        SELECT
          l.lost_report_id,
          f.found_report_id,

          GREATEST(
            0,
            LEAST(1, 1 - (li.embedding <=> fi.embedding))
          ) AS similarity,

          (
            (
              GREATEST(
                0,
                LEAST(1, 1 - (li.embedding <=> fi.embedding))
              ) * 70
            )
            +
            (
              CASE
                WHEN li.category_id = fi.category_id THEN 15
                ELSE 0
              END
            )
            +
            (
              CASE
                WHEN li.color IS NOT NULL
                  AND fi.color IS NOT NULL
                  AND LOWER(TRIM(li.color)) = LOWER(TRIM(fi.color))
                THEN 10
                ELSE 0
              END
            )
            +
            (
              CASE
                WHEN l.location_id = f.location_id THEN 5
                ELSE 0
              END
            )
          ) AS refined_score

        FROM lost_report l
        JOIN item li ON li.item_id = l.item_id
        JOIN found_report f ON f.status = 'open'
        JOIN item fi ON fi.item_id = f.item_id

        WHERE l.status = 'open'
          AND li.embedding IS NOT NULL
          AND fi.embedding IS NOT NULL
          AND (1 - (li.embedding <=> fi.embedding)) >= 0.35
      ),

      saved_matches AS (
        INSERT INTO match (
          lost_report_id,
          found_report_id,
          similarity_score,
          match_score,
          generated_at
        )
        SELECT
          lost_report_id,
          found_report_id,
          ROUND(similarity::numeric, 4),
          ROUND(refined_score::numeric, 2),
          NOW()
        FROM candidate_matches

        ON CONFLICT (lost_report_id, found_report_id)
        DO UPDATE SET
          similarity_score = EXCLUDED.similarity_score,
          match_score = EXCLUDED.match_score,
          generated_at = NOW()

        RETURNING match_id
      )

      SELECT COUNT(*)::int AS generated_count
      FROM saved_matches;
    `);

    return NextResponse.json({
      success: true,
      generatedCount: result.rows[0].generated_count,
      message: "Match generation completed.",
    });
  } catch (error) {
    console.error("Match generation failed:", error);

    return NextResponse.json(
      { success: false, error: "Failed to generate matches." },
      { status: 500 }
    );
  }
}