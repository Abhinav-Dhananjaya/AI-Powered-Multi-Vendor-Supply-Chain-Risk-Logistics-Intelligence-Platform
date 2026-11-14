# Phase 1 — Conceptual & Relational Design

**Project:** AI-Powered Multi-Vendor Supply Chain Risk & Logistics Intelligence Platform
**Architecture:** Polyglot persistence — PostgreSQL (OLTP + pgvector) · MongoDB Atlas (IoT telemetry) · FastAPI (embeddings) · Next.js (UI/API)

```
 Next.js (App Router) ──► PostgreSQL 16 + pgvector   (entities, ACID, views, triggers, embeddings)
        │            └──► MongoDB Atlas               (time-series telemetry)
        └──► FastAPI /embed (all-MiniLM-L6-v2, 384-d) ──► vectors stored in PostgreSQL
```

---

## 1. ER Diagram Specification

### 1.1 Entities, attributes, keys

Notation: **PK** primary key · *FK* foreign key · U unique · NN not null

| Entity | Attributes |
|---|---|
| **ROLE** | **role_id** (PK), role_name (U, NN) ∈ {Admin, Procurement, Logistics, Analyst} |
| **APP_USER** | **user_id** (PK), email (U, NN), password_hash (NN), full_name (NN), *role_id* (FK→ROLE), is_active, created_at |
| **SUPPLIER** | **supplier_id** (PK), name (U, NN), country (NN), contact_email (U), tier ∈ {1,2,3}, is_active, onboarded_on |
| **WAREHOUSE** | **warehouse_id** (PK), name (U, NN), city, country, capacity_units (>0) |
| **PRODUCT** | **product_id** (PK), sku (U, NN), name (NN), unit_of_measure |
| **SUPPLIER_PRODUCT** (associative) | **(supplier_id, product_id)** (composite PK, both FK), unit_price (>0), lead_time_days (>0), available_stock (≥0) |
| **INVENTORY** (associative) | **(warehouse_id, product_id)** (composite PK, both FK), quantity_on_hand (≥0), reorder_level (≥0), updated_at |
| **PURCHASE_ORDER** | **po_id** (PK), *supplier_id* (FK), *warehouse_id* (FK), *created_by* (FK→APP_USER), status, order_date, expected_date, total_amount (≥0) |
| **PO_ITEM** | **po_item_id** (PK), *po_id* (FK), *product_id* (FK), quantity (>0), unit_price (>0); U(po_id, product_id) |
| **SHIPMENT** | **shipment_id** (PK), *po_id* (FK), carrier (NN), tracking_no (U), vehicle_id, status, shipped_at, eta, delivered_at |
| **SHIPMENT_TELEMETRY_PING** | **ping_id** (PK), *shipment_id* (FK), recorded_at, speed_kmh (≥0), latitude, longitude, mongo_doc_id |
| **SHIPMENT_STATUS_LOG** | **log_id** (PK), *shipment_id* (FK), old_status, new_status, reason, changed_at |
| **RISK_DOCUMENT** | **doc_id** (PK), doc_type ∈ {Contract, News}, *supplier_id* (FK, nullable), title, content, source_url, published_at, embedding `vector(384)` |

### 1.2 Relationships & cardinalities

| Relationship | Cardinality | Notes |
|---|---|---|
| ROLE – APP_USER | 1 : N | A user has exactly one role; a role has many users |
| APP_USER – PURCHASE_ORDER | 1 : N | `created_by`; a PO is created by one user |
| SUPPLIER – PURCHASE_ORDER | 1 : N | Mandatory on the PO side |
| WAREHOUSE – PURCHASE_ORDER | 1 : N | Destination warehouse |
| PURCHASE_ORDER – PO_ITEM | 1 : N (identifying-like, cascade) | A PO has ≥1 items |
| PRODUCT – PO_ITEM | 1 : N | |
| SUPPLIER – PRODUCT | M : N via SUPPLIER_PRODUCT | Supplier catalogue with price/lead time/stock |
| WAREHOUSE – PRODUCT | M : N via INVENTORY | Stock per warehouse |
| PURCHASE_ORDER – SHIPMENT | 1 : N | A PO can be split into several shipments (0..N until dispatched) |
| SHIPMENT – TELEMETRY_PING | 1 : N | Relational mirror of Mongo telemetry (only fields needed by triggers) |
| SHIPMENT – STATUS_LOG | 1 : N | Audit trail written by trigger |
| SUPPLIER – RISK_DOCUMENT | 1 : N (optional) | News may be unlinked (`supplier_id` NULL) |

### 1.3 Text ER diagram

```
ROLE 1───N APP_USER 1───N PURCHASE_ORDER N───1 SUPPLIER
                                │  │  │
                                │  │  └─N───1 WAREHOUSE
                                │  └─1───N PO_ITEM N───1 PRODUCT
                                └─1───N SHIPMENT 1───N TELEMETRY_PING
                                              └─1───N STATUS_LOG
SUPPLIER M───N PRODUCT   (SUPPLIER_PRODUCT)
WAREHOUSE M───N PRODUCT  (INVENTORY)
SUPPLIER 1───N RISK_DOCUMENT (optional)
```

---

## 2. Relational Schema (3NF)

The executable version is `db/001_schema.sql`. Summary with types:

| Table | Columns (type) | Key constraints |
|---|---|---|
| roles | role_id SMALLINT IDENTITY, role_name VARCHAR(20) | PK; UNIQUE; CHECK IN (4 roles) |
| users | user_id INT, email VARCHAR(255), password_hash TEXT, full_name VARCHAR(120), role_id SMALLINT, is_active BOOL, created_at TIMESTAMPTZ | PK; UNIQUE(email); CHECK email regex; FK role |
| suppliers | supplier_id INT, name VARCHAR(150), country VARCHAR(80), contact_email VARCHAR(255), tier SMALLINT, is_active, onboarded_on DATE | PK; UNIQUE(name); CHECK tier IN (1,2,3) |
| warehouses | warehouse_id INT, name, city, country, capacity_units INT | PK; CHECK capacity > 0 |
| products | product_id INT, sku VARCHAR(40), name, unit_of_measure | PK; UNIQUE(sku) |
| supplier_products | supplier_id, product_id, unit_price NUMERIC(12,2), lead_time_days SMALLINT, available_stock INT | composite PK; CHECKs |
| inventory | warehouse_id, product_id, quantity_on_hand INT, reorder_level INT | composite PK; CHECK ≥ 0 |
| purchase_orders | po_id BIGINT, supplier_id, warehouse_id, created_by, status VARCHAR(20), order_date DATE, expected_date DATE, total_amount NUMERIC(14,2) | CHECK status IN (...); CHECK expected_date ≥ order_date |
| po_items | po_item_id BIGINT, po_id, product_id, quantity INT, unit_price NUMERIC(12,2) | UNIQUE(po_id, product_id); CHECK quantity > 0 |
| shipments | shipment_id BIGINT, po_id, carrier, tracking_no, vehicle_id, status, shipped_at, eta, delivered_at (TIMESTAMPTZ) | CHECK status; CHECK Delivered ⇒ delivered_at NOT NULL |
| shipment_telemetry_pings | ping_id BIGINT, shipment_id, recorded_at, speed_kmh NUMERIC(6,2), latitude NUMERIC(9,6), longitude NUMERIC(9,6) | CHECK lat/lon ranges |
| shipment_status_log | log_id BIGINT, shipment_id, old_status, new_status, reason, changed_at | FK |
| risk_documents | doc_id BIGINT, doc_type, supplier_id, title, content TEXT, source_url, published_at, embedding vector(384) | CHECK doc_type |

### 3NF justification

- **1NF:** every column is atomic; line items are in `po_items`, not in an array column on `purchase_orders`.
- **2NF:** in composite-key tables (`supplier_products`, `inventory`) every non-key column depends on the *whole* key (price depends on supplier **and** product; stock depends on warehouse **and** product).
- **3NF:** no transitive dependencies. Role name lives in `roles`, not repeated on `users`; product name/SKU live in `products`, not on `po_items`.
- **Deliberate, documented denormalisations:**
  - `po_items.unit_price` is a *price snapshot* at order time (catalogue prices change; history must not).
  - `purchase_orders.total_amount` is a derived total maintained inside the ordering transaction for fast reporting. It could be a view if you prefer strict purity.

> **Design note on "deducting inventory":** placing a purchase order *reserves vendor stock* — `supplier_products.available_stock` is decremented atomically. Warehouse `inventory.quantity_on_hand` increases on goods receipt, which is a different event from placing an order.

---

## 3. NoSQL Data Model — MongoDB `iot_telemetry_logs`

Time-series collection (`timeField: timestamp`, `metaField: metadata`). Sensor fields differ per device type, so nested objects are optional and dynamic.

```json
{
  "_id": { "$oid": "6720a1f4c3b2a95e4d1f0a11" },
  "timestamp": { "$date": "2026-10-31T08:42:10.000Z" },
  "metadata": {
    "shipment_id": 3,
    "tracking_no": "TRK-0003-DE",
    "device_id": "IOT-GW-7731",
    "vehicle_id": "TRUCK-DE-4417",
    "carrier": "Rhine Freight"
  },
  "gps": {
    "type": "Point",
    "coordinates": [8.6821, 50.1109],
    "speed_kmh": 0,
    "heading_deg": 214,
    "accuracy_m": 4.5
  },
  "sensors": {
    "temperature_c": 7.9,
    "humidity_pct": 61.2,
    "shock_g": 0.2,
    "door_open": false
  },
  "anomalies": [
    {
      "code": "TEMP_HIGH",
      "severity": "WARN",
      "threshold": 6.0,
      "observed": 7.9,
      "detected_at": { "$date": "2026-10-31T08:42:10.000Z" }
    }
  ],
  "battery_pct": 73,
  "firmware": "2.4.1"
}
```

**Why MongoDB here:** high-volume append-only writes, heterogeneous sensor payloads, native `2dsphere` geo queries, TTL retention. Only the minimum (speed, lat, lon, timestamp) is mirrored to PostgreSQL so the "stalled shipment" trigger stays ACID and in-database.

Indexes (see `mongo/init.js`): `{ "metadata.shipment_id": 1, timestamp: -1 }`, `2dsphere` on `gps`, partial index on `anomalies.code`, TTL 180 days.

---

## 4. Vector Data Model — `risk_documents`

| Column | Type | Purpose |
|---|---|---|
| doc_id | BIGINT IDENTITY PK | |
| doc_type | VARCHAR(20) CHECK IN ('Contract','News') | |
| supplier_id | INT NULL FK→suppliers | link when known |
| title | VARCHAR(255) NOT NULL | |
| content | TEXT NOT NULL | embedded text |
| source_url | TEXT | |
| published_at | TIMESTAMPTZ | |
| **embedding** | **vector(384)** | `all-MiniLM-L6-v2` output (L2-normalised) |
| embedding_model | VARCHAR(80) | provenance for re-embedding |
| created_at | TIMESTAMPTZ | |

- Index: `HNSW (embedding vector_cosine_ops)`, `m=16, ef_construction=64`.
- Query: `ORDER BY embedding <=> $1::vector LIMIT k`; similarity = `1 - (embedding <=> $1)`.
- `<=>` is cosine **distance** (0 = identical, 2 = opposite).
