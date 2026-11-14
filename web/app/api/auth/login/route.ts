// app/api/auth/login/route.ts — verifies credentials in Postgres (pgcrypto), issues JWT cookie
import { NextRequest, NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { signSession, SESSION_COOKIE, Role } from "@/lib/auth";

export async function POST(req: NextRequest) {
  const { email, password } = await req.json().catch(() => ({}));
  if (typeof email !== "string" || typeof password !== "string") {
    return NextResponse.json({ error: "email and password required" }, { status: 400 });
  }

  const { rows } = await pool.query(
    `SELECT u.user_id, u.email, r.role_name
       FROM users u JOIN roles r ON r.role_id = u.role_id
      WHERE u.email = $1 AND u.is_active
        AND u.password_hash = crypt($2, u.password_hash)`,
    [email.toLowerCase(), password]
  );
  if (rows.length === 0) {
    return NextResponse.json({ error: "Invalid credentials" }, { status: 401 });
  }

  const token = await signSession({
    userId: rows[0].user_id,
    email: rows[0].email,
    role: rows[0].role_name as Role,
  });
  const res = NextResponse.json({ ok: true, role: rows[0].role_name });
  res.cookies.set(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    maxAge: 60 * 60 * 8,
    path: "/",
  });
  return res;
}
