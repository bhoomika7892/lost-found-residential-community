
import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { executeClaimsAction } from "@/lib/claims-workflow";

export const runtime = "nodejs";

type RouteContext = {
  params: Promise<{ claimId: string }>;
};

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

    const notes =
      typeof body.rejectionNotes === "string"
        ? body.rejectionNotes.trim()
        : "";

    if (!notes) {
      return NextResponse.json(
        { success: false, message: "Rejection notes are required" },
        { status: 400 }
      );
    }

    const result = await executeClaimsAction<{ result: string }>(
      Number(session.user.staffId),
      "claim:reject",
      `SELECT public.reject_claim($1, $2, $3) AS result`,
      [id, notes]
    );

    return NextResponse.json({
      success: true,
      message: result.result,
    });
  } catch (error) {
    console.error("Claim rejection failed:", error);

    return NextResponse.json(
      { success: false, message: "Claim rejection failed" },
      { status: 400 }
    );
  }
}
