export const runtime = "nodejs";

import { processNewItem } from "@/lib/process-new-item";
import { NextResponse } from "next/server";
import { pool } from "@/lib/db";

export async function GET() {
  try {
    const result = await pool.query(`
      SELECT
        fr.found_report_id,
        i.item_id,
        i.item_name,
        i.color,
        i.brand,
        i.description,
        c.category_name,
        l.location_name,
        l.location_type,
        fr.found_date,
        fr.reported_date,
        fr.status
      FROM found_report fr
      JOIN item i ON fr.item_id = i.item_id
      JOIN category c ON i.category_id = c.category_id
      JOIN location l ON fr.location_id = l.location_id
      WHERE fr.status = 'open'
      ORDER BY fr.reported_date DESC, fr.found_report_id DESC;
    `);

    return NextResponse.json({
      success: true,
      count: result.rows.length,
      data: result.rows,
    });
  } catch (error) {
    console.error("Failed to fetch found items:", error);

    return NextResponse.json(
      { success: false, message: "Failed to fetch found items" },
      { status: 500 }
    );
  }
}
export async function POST(request: Request) {
  let client;

  try {
    const body = await request.json();

    const {
      item_name,
      category_id,
      color,
      brand,
      description,
      resident_id,
      location_id,
      found_date,
    } = body;

    if (
      typeof item_name !== "string" ||
      !item_name.trim() ||
      !category_id ||
      !resident_id ||
      !location_id ||
      !found_date
    ) {
      return NextResponse.json(
        { success: false, message: "Missing required fields" },
        { status: 400 }
      );
    }

    if (item_name.trim().length > 100) {
      return NextResponse.json(
        { success: false, message: "Item name must be 100 characters or fewer" },
        { status: 400 }
      );
    }

    const categoryId = Number(category_id);
    const residentId = Number(resident_id);
    const locationId = Number(location_id);

    if (
      !Number.isInteger(categoryId) ||
      !Number.isInteger(residentId) ||
      !Number.isInteger(locationId)
    ) {
      return NextResponse.json(
        { success: false, message: "Invalid category, resident, or location ID" },
        { status: 400 }
      );
    }

    if (
      typeof found_date !== "string" ||
      !/^\d{4}-\d{2}-\d{2}$/.test(found_date) ||
      found_date > new Date().toISOString().slice(0, 10)
    ) {
      return NextResponse.json(
        { success: false, message: "Invalid found date" },
        { status: 400 }
      );
    }

    const cleanOptionalText = (value: unknown) =>
      typeof value === "string" && value.trim() ? value.trim() : null;

    client = await pool.connect();
    await client.query("BEGIN");

    const itemResult = await client.query(
      `INSERT INTO item
        (category_id, item_name, color, brand, description)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING item_id`,
      [
        categoryId,
        item_name.trim(),
        cleanOptionalText(color),
        cleanOptionalText(brand),
        cleanOptionalText(description),
      ]
    );

    const itemId = itemResult.rows[0].item_id;

    const reportResult = await client.query(
      `INSERT INTO found_report
        (item_id, resident_id, location_id, found_date)
       VALUES ($1, $2, $3, $4)
       RETURNING found_report_id, item_id, resident_id, location_id,
                 found_date, reported_date, status`,
      [itemId, residentId, locationId, found_date]
    );

    await client.query("COMMIT");

    // The report is saved. Now generate its embedding and potential matches.
    let matchingUpdate;

    try {
      matchingUpdate = await processNewItem(Number(itemId));
    } catch (matchingError) {
      console.error(
        "Report saved, but automatic matching failed:",
        matchingError
      );

      matchingUpdate = {
        embeddingGenerated: false,
        generatedCount: 0,
        warning: "Report saved, but potential matches could not be updated.",
      };
    }
    return NextResponse.json(
      {
        success: true,
        message: "Found item reported successfully",
        data: reportResult.rows[0],
        matchingUpdate,
      },
      { status: 201 }
    );
  } catch (error) {
    if (client) {
      await client.query("ROLLBACK").catch(() => {});
    }

    console.error("Error creating found report:", error);

    return NextResponse.json(
      { success: false, message: "Failed to create found report" },
      { status: 400 }
    );
  } finally {
    client?.release();
  }
}