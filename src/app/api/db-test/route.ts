import { NextResponse } from "next/server";
import { pool } from "@/lib/db";

export async function GET() {
  try {
    const result = await pool.query(
      "SELECT current_database() AS database, NOW() AS server_time"
    );

    return NextResponse.json({
      success: true,
      message: "Connected to PostgreSQL",
      data: result.rows[0],
    });
  } catch (error) {
    console.error("Database connection failed:", error);

    return NextResponse.json(
      {
        success: false,
        message: "Database connection failed",
      },
      { status: 500 }
    );
  }
}