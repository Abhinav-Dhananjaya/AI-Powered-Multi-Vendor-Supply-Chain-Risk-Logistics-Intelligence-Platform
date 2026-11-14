// app/api/telemetry/route.ts — polyglot ingestion: MongoDB (full payload) + PostgreSQL (trigger-relevant fields)
import { NextRequest, NextResponse } from "next/server";
import { getMongoDb } from "@/lib/mongo";
import { pool } from "@/lib/db";
import { getSessionFromRequest, can } from "@/lib/auth";

export async function POST(req: NextRequest) {
  const session = await getSessionFromRequest(req);
  if (!session) return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });
  if (!can(session, "telemetry:write")) return NextResponse.json({ error: "Forbidden" }, { status: 403 });

  const b = await req.json().catch(() => null);
  const ok =
    b && Number.isInteger(b.shipmentId) &&
    typeof b.lat === "number" && Math.abs(b.lat) <= 90 &&
    typeof b.lon === "number" && Math.abs(b.lon) <= 180 &&
    typeof b.speedKmh === "number" && b.speedKmh >= 0;
  if (!ok) return NextResponse.json({ error: "Invalid telemetry payload" }, { status: 400 });

  const ts = b.timestamp ? new Date(b.timestamp) : new Date();
  if (Number.isNaN(ts.getTime())) return NextResponse.json({ error: "Invalid timestamp" }, { status: 400 });

  // 1) Full, schema-flexible document -> MongoDB time-series collection
  const mongo = await getMongoDb();
  const doc = {
    timestamp: ts,
    metadata: { shipment_id: b.shipmentId, device_id: b.deviceId ?? null, vehicle_id: b.vehicleId ?? null },
    gps: { type: "Point", coordinates: [b.lon, b.lat], speed_kmh: b.speedKmh },
    sensors: b.sensors ?? {},
    anomalies: Array.isArray(b.anomalies) ? b.anomalies : [],
  };
  const { insertedId } = await mongo.collection("iot_telemetry_logs").insertOne(doc as any);

  // 2) Minimal relational mirror -> fires trg_flag_stalled_shipment
  try {
    await pool.query(
      `INSERT INTO shipment_telemetry_pings (shipment_id, recorded_at, speed_kmh, latitude, longitude, mongo_doc_id)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [b.shipmentId, ts, b.speedKmh, b.lat, b.lon, insertedId.toString()]
    );
  } catch (err: any) {
    if (err.code === "23503") return NextResponse.json({ error: "Unknown shipment" }, { status: 422 });
    throw err;
  }
  return NextResponse.json({ ok: true, mongoId: insertedId.toString() }, { status: 201 });
}
