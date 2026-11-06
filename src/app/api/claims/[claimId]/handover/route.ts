
import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { executeClaimsAction } from "@/lib/claims-workflow";

export const runtime = "nodejs";

type RouteContext = {
  params: Promise<{ claimId: string }>;
};

const allowedMethods = [
  "photo_id",
  "resident_id",
  "security_question",
  "other",
];

export async function POST(
  request: Request,
  context: RouteContext
) {
  const session = await auth();

  if (
    !session?.user ||
    !["staff", "admin"].includes(session.user.role ?? "") ||
    !session.user.staffId
  ) {
    return NextResponse.json(
      { success: false, message: "Unauthorized" },
      { status: 401 }
    );
  }

  const { claimId } = await context.params;
  const id = Number(claimId);

  if (!Number.isSafeInteger(id) || id <= 0) {
    return NextResponse.json(
      { success: false, message: "Invalid claim ID" },
      { status: 400 }
    );
  }

  try {
    const body = await request.json();

    const method =
      typeof body.verificationMethod === "string"
        ? body.verificationMethod.trim()
        : "";

    const remarks =
      typeof body.remarks === "string"
        ? body.remarks.trim() || null
        : null;

    if (!allowedMethods.includes(method)) {
      return NextResponse.json(
        {
          success: false,
          message: "Invalid verification method",
          allowedMethods,
        },
        { status: 400 }
      );
    }

    const result = await executeClaimsAction<{ result: string }>(
      Number(session.user.staffId),
      "handover:record",
      `SELECT public.record_handover(
        $1,
        $2,
        $3,
        $4::timestamp,
        $5
      ) AS result`,
      [id, method, remarks, new Date()]
    );

    return NextResponse.json({
      success: true,
      message: result.result,
    });
  } catch (error) {
    console.error("Handover recording failed:", error);

    return NextResponse.json(
      {
        success: false,
        message: "Handover recording failed",
      },
      { status: 400 }
    );
  }
}
