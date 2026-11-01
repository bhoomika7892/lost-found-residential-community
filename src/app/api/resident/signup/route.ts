import { NextResponse } from "next/server";
import bcrypt from "bcryptjs";
import { pool } from "@/lib/db";

export async function POST(request: Request) {
  try {
    const body = await request.json();

    const name = typeof body.name === "string" ? body.name.trim() : "";
    const email =
      typeof body.email === "string"
        ? body.email.trim().toLowerCase()
        : "";
    const phone = typeof body.phone === "string" ? body.phone.trim() : "";
    const password =
      typeof body.password === "string" ? body.password : "";
    const apartmentId = Number(body.apartmentId);

    if (!name || !email || !phone || !password || !body.apartmentId) {
      return NextResponse.json(
        { message: "All fields are required." },
        { status: 400 }
      );
    }

    if (name.length > 100) {
      return NextResponse.json(
        { message: "Name must be 100 characters or fewer." },
        { status: 400 }
      );
    }

    if (!/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(email)) {
      return NextResponse.json(
        { message: "Enter a valid email address." },
        { status: 400 }
      );
    }

    if (!/^[0-9]{10}$/.test(phone)) {
      return NextResponse.json(
        { message: "Phone number must contain exactly 10 digits." },
        { status: 400 }
      );
    }

    if (password.length < 8) {
      return NextResponse.json(
        { message: "Password must be at least 8 characters long." },
        { status: 400 }
      );
    }

    if (
      !Number.isInteger(apartmentId) ||
      apartmentId < 1
    ) {
      return NextResponse.json(
        { message: "Select a valid apartment." },
        { status: 400 }
      );
    }

    const apartmentResult = await pool.query(
      "SELECT apartment_id FROM apartment WHERE apartment_id = $1",
      [apartmentId]
    );

    if (apartmentResult.rows.length === 0) {
      return NextResponse.json(
        { message: "Selected apartment does not exist." },
        { status: 400 }
      );
    }

    const existingResident = await pool.query(
      "SELECT resident_id FROM resident WHERE LOWER(email) = $1",
      [email]
    );

    if (existingResident.rows.length > 0) {
      return NextResponse.json(
        { message: "An account with this email already exists." },
        { status: 409 }
      );
    }

    const passwordHash = await bcrypt.hash(password, 12);

    await pool.query(
      `INSERT INTO resident
        (name, email, phone, resident_status, apartment_id, password_hash)
       VALUES ($1, $2, $3, 'active', $4, $5)`,
      [name, email, phone, apartmentId, passwordHash]
    );

    return NextResponse.json(
      { message: "Resident account created successfully." },
      { status: 201 }
    );
  } catch (error: unknown) {
    // Handle duplicate email safely if two signup requests happen together.
    if (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === "23505"
    ) {
      return NextResponse.json(
        { message: "An account with this email already exists." },
        { status: 409 }
      );
    }

    console.error("Resident signup error:", error);

    return NextResponse.json(
      { message: "Unable to create account right now." },
      { status: 500 }
    );
  }
}