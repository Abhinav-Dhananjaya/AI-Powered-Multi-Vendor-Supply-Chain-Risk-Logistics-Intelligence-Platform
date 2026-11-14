// lib/auth.ts — JWT session + role-based access control (RBAC)
import { SignJWT, jwtVerify } from "jose";
import { cookies } from "next/headers";
import type { NextRequest } from "next/server";

export type Role = "Admin" | "Procurement" | "Logistics" | "Analyst";
export interface Session {
  userId: number;
  email: string;
  role: Role;
}

const COOKIE = "session";
const secret = () => {
  const s = process.env.JWT_SECRET;
  if (!s || s.length < 32) throw new Error("JWT_SECRET must be set (32+ chars)");
  return new TextEncoder().encode(s);
};

export async function signSession(session: Session): Promise<string> {
  return new SignJWT({ ...session })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime("8h")
    .sign(secret());
}

async function verify(token?: string | null): Promise<Session | null> {
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, secret());
    return payload as unknown as Session;
  } catch {
    return null;
  }
}

/** For Route Handlers: reads the cookie or an `Authorization: Bearer` header. */
export async function getSessionFromRequest(req: NextRequest): Promise<Session | null> {
  const bearer = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  return verify(req.cookies.get(COOKIE)?.value ?? bearer);
}

/** For Server Components / Server Actions. */
export async function getSession(): Promise<Session | null> {
  const store = await cookies(); // async in Next.js 15+
  return verify(store.get(COOKIE)?.value);
}

export const SESSION_COOKIE = COOKIE;

/** Permission matrix: which roles may perform which action. */
export const PERMISSIONS = {
  "orders:read":   ["Admin", "Procurement", "Logistics", "Analyst"],
  "orders:create": ["Admin", "Procurement"],
  "risk:read":     ["Admin", "Procurement", "Analyst"],
  "risk:search":   ["Admin", "Procurement", "Analyst"],
  "telemetry:write": ["Admin", "Logistics"],
} as const satisfies Record<string, readonly Role[]>;

export type Permission = keyof typeof PERMISSIONS;

export function can(session: Session | null, permission: Permission): boolean {
  return !!session && (PERMISSIONS[permission] as readonly Role[]).includes(session.role);
}
