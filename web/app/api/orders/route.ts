// app/api/orders/route.ts — RBAC-protected order placement (ACID, SAVEPOINT) + listing
import { NextRequest, NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { getSessionFromRequest, can } from "@/lib/auth";

interface OrderItem { productId: number; quantity: number }
interface OrderBody { supplierId: number; warehouseId: number; items: OrderItem[]; carrier?: string }

const isPosInt = (n: unknown): n is number => Number.isInteger(n) && (n as number) > 0;

function validate(b: any): b is OrderBody {
  return (
    b && isPosInt(b.supplierId) && isPosInt(b.warehouseId) &&
    Array.isArray(b.items) && b.items.length > 0 && b.items.length <= 100 &&
    b.items.every((i: any) => isPosInt(i?.productId) && isPosInt(i?.quantity))
  );
}

export async function POST(req: NextRequest) {
  const session = await getSessionFromRequest(req);
  if (!session) return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });
  if (!can(session, "orders:create")) {
    return NextResponse.json({ error: "Forbidden: requires Admin or Procurement" }, { status: 403 });
  }

  const body = await req.json().catch(() => null);
  if (!validate(body)) {
    return NextResponse.json({ error: "Invalid body" }, { status: 400 });
  }

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    // 1) Create PO + items and deduct vendor stock atomically (stored function)
    const { rows } = await client.query<{ po_id: string }>(
      "SELECT fn_place_purchase_order($1, $2, $3, $4::jsonb) AS po_id",
      [body.supplierId, body.warehouseId, session.userId, JSON.stringify(body.items)]
    );
    const poId = rows[0].po_id;

    // 2) Optional step guarded by a SAVEPOINT: a failure here must NOT lose the order
    await client.query("SAVEPOINT create_pending_shipment");
    try {
      await client.query(
        `INSERT INTO shipments (po_id, carrier, status) VALUES ($1, $2, 'Pending')`,
        [poId, body.carrier ?? "TBD"]
      );
    } catch {
      await client.query("ROLLBACK TO SAVEPOINT create_pending_shipment");
    }

    await client.query("COMMIT");
    return NextResponse.json({ poId }, { status: 201 });
  } catch (err: any) {
    await client.query("ROLLBACK").catch(() => undefined);
    // Map database errors to HTTP codes
    if (err.code === "PS001") return NextResponse.json({ error: err.message }, { status: 409 }); // stock
    if (err.code === "23503") return NextResponse.json({ error: "Unknown supplier/warehouse/product" }, { status: 422 });
    if (err.code === "23505") return NextResponse.json({ error: "Duplicate product in order" }, { status: 422 });
    if (typeof err.message === "string" && /^(EMPTY_ORDER|SUPPLIER_INACTIVE)/.test(err.message)) {
      return NextResponse.json({ error: err.message }, { status: 422 });
    }
    console.error("order failed", err);
    return NextResponse.json({ error: "Internal error" }, { status: 500 });
  } finally {
    client.release();
  }
}

export async function GET(req: NextRequest) {
  const session = await getSessionFromRequest(req);
  if (!session) return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });
  if (!can(session, "orders:read")) return NextResponse.json({ error: "Forbidden" }, { status: 403 });

  const { rows } = await pool.query(
    `SELECT po.po_id, s.name AS supplier, w.name AS warehouse, po.status,
            po.order_date, po.expected_date, po.total_amount
       FROM purchase_orders po
       JOIN suppliers s  ON s.supplier_id  = po.supplier_id
       JOIN warehouses w ON w.warehouse_id = po.warehouse_id
      ORDER BY po.po_id DESC LIMIT 100`
  );
  return NextResponse.json({ orders: rows });
}
