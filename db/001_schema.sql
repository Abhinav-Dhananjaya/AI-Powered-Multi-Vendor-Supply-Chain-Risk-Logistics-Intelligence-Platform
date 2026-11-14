-- =====================================================================
-- 001_schema.sql  |  Tables, constraints, indexes
-- Target: PostgreSQL 15+ with pgvector 0.5+ (HNSW)
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- crypt()/gen_salt() for password hashing

-- ---------- Identity & RBAC ----------
CREATE TABLE roles (
    role_id    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_name  VARCHAR(20) NOT NULL UNIQUE
               CHECK (role_name IN ('Admin','Procurement','Logistics','Analyst'))
);

CREATE TABLE users (
    user_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         VARCHAR(255) NOT NULL UNIQUE
                  CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    password_hash TEXT         NOT NULL,
    full_name     VARCHAR(120) NOT NULL,
    role_id       SMALLINT     NOT NULL REFERENCES roles(role_id),
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------- Master data ----------
CREATE TABLE suppliers (
    supplier_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(150) NOT NULL UNIQUE,
    country       VARCHAR(80)  NOT NULL,
    contact_email VARCHAR(255) UNIQUE,
    tier          SMALLINT     NOT NULL DEFAULT 2 CHECK (tier IN (1,2,3)),
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    onboarded_on  DATE         NOT NULL DEFAULT CURRENT_DATE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE warehouses (
    warehouse_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           VARCHAR(120) NOT NULL UNIQUE,
    city           VARCHAR(80)  NOT NULL,
    country        VARCHAR(80)  NOT NULL,
    capacity_units INT          NOT NULL CHECK (capacity_units > 0)
);

CREATE TABLE products (
    product_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku             VARCHAR(40)  NOT NULL UNIQUE,
    name            VARCHAR(150) NOT NULL,
    unit_of_measure VARCHAR(20)  NOT NULL DEFAULT 'unit'
);

-- Supplier catalogue (M:N). available_stock = vendor stock reserved by POs.
CREATE TABLE supplier_products (
    supplier_id     INT           NOT NULL REFERENCES suppliers(supplier_id) ON DELETE CASCADE,
    product_id      INT           NOT NULL REFERENCES products(product_id)   ON DELETE CASCADE,
    unit_price      NUMERIC(12,2) NOT NULL CHECK (unit_price > 0),
    lead_time_days  SMALLINT      NOT NULL CHECK (lead_time_days > 0),
    available_stock INT           NOT NULL DEFAULT 0 CHECK (available_stock >= 0),
    PRIMARY KEY (supplier_id, product_id)
);

-- Warehouse stock (M:N)
CREATE TABLE inventory (
    warehouse_id     INT         NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE CASCADE,
    product_id       INT         NOT NULL REFERENCES products(product_id)     ON DELETE CASCADE,
    quantity_on_hand INT         NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
    reorder_level    INT         NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (warehouse_id, product_id)
);

-- ---------- Transactions ----------
CREATE TABLE purchase_orders (
    po_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id   INT           NOT NULL REFERENCES suppliers(supplier_id),
    warehouse_id  INT           NOT NULL REFERENCES warehouses(warehouse_id),
    created_by    INT           NOT NULL REFERENCES users(user_id),
    status        VARCHAR(20)   NOT NULL DEFAULT 'Placed'
                  CHECK (status IN ('Draft','Placed','Confirmed','In Transit','Received','Cancelled')),
    order_date    DATE          NOT NULL DEFAULT CURRENT_DATE,
    expected_date DATE          NOT NULL,
    total_amount  NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    CONSTRAINT chk_po_dates CHECK (expected_date >= order_date)
);

CREATE TABLE po_items (
    po_item_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_id      BIGINT        NOT NULL REFERENCES purchase_orders(po_id) ON DELETE CASCADE,
    product_id INT           NOT NULL REFERENCES products(product_id),
    quantity   INT           NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price > 0),   -- price snapshot
    CONSTRAINT uq_po_product UNIQUE (po_id, product_id)
);

CREATE TABLE shipments (
    shipment_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_id        BIGINT       NOT NULL REFERENCES purchase_orders(po_id) ON DELETE CASCADE,
    carrier      VARCHAR(80)  NOT NULL,
    tracking_no  VARCHAR(60)  UNIQUE,
    vehicle_id   VARCHAR(40),
    status       VARCHAR(20)  NOT NULL DEFAULT 'Pending'
                 CHECK (status IN ('Pending','In Transit','Delayed','Delivered','Cancelled')),
    shipped_at   TIMESTAMPTZ,
    eta          TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    CONSTRAINT chk_delivered CHECK (status <> 'Delivered' OR delivered_at IS NOT NULL),
    CONSTRAINT chk_eta CHECK (eta IS NULL OR shipped_at IS NULL OR eta >= shipped_at)
);

-- Relational mirror of Mongo telemetry (only what triggers need)
CREATE TABLE shipment_telemetry_pings (
    ping_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id  BIGINT        NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    recorded_at  TIMESTAMPTZ   NOT NULL,
    speed_kmh    NUMERIC(6,2)  NOT NULL CHECK (speed_kmh >= 0),
    latitude     NUMERIC(9,6)  NOT NULL CHECK (latitude  BETWEEN  -90 AND  90),
    longitude    NUMERIC(9,6)  NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    mongo_doc_id VARCHAR(24)
);

CREATE TABLE shipment_status_log (
    log_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id BIGINT       NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    old_status  VARCHAR(20),
    new_status  VARCHAR(20)  NOT NULL,
    reason      TEXT,
    changed_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------- Vector store ----------
CREATE TABLE risk_documents (
    doc_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_type        VARCHAR(20)  NOT NULL CHECK (doc_type IN ('Contract','News')),
    supplier_id     INT          REFERENCES suppliers(supplier_id) ON DELETE SET NULL,
    title           VARCHAR(255) NOT NULL,
    content         TEXT         NOT NULL,
    source_url      TEXT,
    published_at    TIMESTAMPTZ,
    embedding       vector(384),                     -- all-MiniLM-L6-v2
    embedding_model VARCHAR(80)  NOT NULL DEFAULT 'sentence-transformers/all-MiniLM-L6-v2',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- =====================================================================
-- Indexes
-- (PK/UNIQUE constraints already create B-Tree indexes.)
-- =====================================================================
CREATE INDEX idx_suppliers_country        ON suppliers (country);
CREATE INDEX idx_po_supplier              ON purchase_orders (supplier_id);
CREATE INDEX idx_po_warehouse             ON purchase_orders (warehouse_id);
CREATE INDEX idx_po_status_date           ON purchase_orders (status, order_date DESC);
CREATE INDEX idx_po_items_product         ON po_items (product_id);
CREATE INDEX idx_shipments_po             ON shipments (po_id);
CREATE INDEX idx_shipments_open           ON shipments (status) WHERE status IN ('Pending','In Transit','Delayed');  -- partial
CREATE INDEX idx_shipments_vehicle_hash   ON shipments USING HASH (vehicle_id);                                      -- equality only
CREATE INDEX idx_pings_shipment_time      ON shipment_telemetry_pings (shipment_id, recorded_at DESC);
CREATE INDEX idx_status_log_shipment      ON shipment_status_log (shipment_id, changed_at DESC);
CREATE INDEX idx_inventory_product        ON inventory (product_id);
CREATE INDEX idx_risk_docs_supplier       ON risk_documents (supplier_id);

-- ANN index for cosine distance (<=>). HNSW: better recall/latency than IVFFlat, no training step.
CREATE INDEX idx_risk_docs_embedding_hnsw
    ON risk_documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
-- IVFFlat alternative (needs data loaded first):
-- CREATE INDEX idx_risk_docs_embedding_ivf ON risk_documents
--     USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
-- Query-time recall knob:  SET hnsw.ef_search = 80;
