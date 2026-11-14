// mongo/init.js — run with:  mongosh "$MONGODB_URI" mongo/init.js
const dbName = "scm_telemetry";
const database = db.getSiblingDB(dbName);

if (!database.getCollectionNames().includes("iot_telemetry_logs")) {
  database.createCollection("iot_telemetry_logs", {
    timeseries: { timeField: "timestamp", metaField: "metadata", granularity: "minutes" },
    expireAfterSeconds: 60 * 60 * 24 * 180, // retain 180 days
  });
}

const logs = database.iot_telemetry_logs;

// Per-shipment history, newest first
logs.createIndex({ "metadata.shipment_id": 1, timestamp: -1 });
// Geo queries (e.g. "which vehicles are within 50 km of Rotterdam?"); needs MongoDB >= 6.0 for time-series
logs.createIndex({ gps: "2dsphere" });
// Quick anomaly filtering
logs.createIndex({ "anomalies.code": 1, timestamp: -1 });

// Sample document
logs.insertOne({
  timestamp: new Date(),
  metadata: { shipment_id: 3, tracking_no: "TRK-0003-DE", device_id: "IOT-GW-7731", vehicle_id: "TRUCK-DE-4417", carrier: "Rhine Freight" },
  gps: { type: "Point", coordinates: [8.6821, 50.1109], speed_kmh: 0, heading_deg: 214, accuracy_m: 4.5 },
  sensors: { temperature_c: 7.9, humidity_pct: 61.2, shock_g: 0.2, door_open: false },
  anomalies: [{ code: "TEMP_HIGH", severity: "WARN", threshold: 6.0, observed: 7.9 }],
  battery_pct: 73,
  firmware: "2.4.1",
});
