import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { executeClaimsAction } from "@/lib/claims-workflow";

export const runtime = "nodejs";

type RouteContext = {
  params: Promise<{ claimId: string }>;
};

export async function POST(
  _request: Request,
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
  const staffId = Number(session.user.staffId);

  if (!Number.isSafeInteger(id) || id <= 0) {
    return NextResponse.json(
      { success: false, message: "Invalid claim ID" },
      { status: 400 }
    );
  }

  if (!Number.isSafeInteger(staffId) || staffId <= 0) {
    return NextResponse.json(
      { success: false, message: "Invalid staff identity" },
      { status: 401 }
    );
  }

  try {
    const result = await executeClaimsAction<{ result: string }>(
      staffId,
      "claim:approve",
      `SELECT public.approve_claim($1, $2) AS result`,
      [id]
    );

    return NextResponse.json({
      success: true,
      message: result.result,
    });
  } catch (error) {
    console.error("Claim approval failed:", error);
    const pgError = error as { code?: string; message?: string };
    const message =
      pgError.code === "P0001" && pgError.message
        ? pgError.message
        : "Claim approval failed";
    return NextResponse.json({ success: false, message }, { status: 400 });
  }
}