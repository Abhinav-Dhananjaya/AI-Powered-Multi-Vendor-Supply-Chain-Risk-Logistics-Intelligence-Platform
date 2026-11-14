-- =====================================================================
-- 004_seed.sql  |  Sample data (run once on a fresh database, after 001 + 002)
-- IDs are identity-generated and referenced by insertion order (1..n).
-- Demo logins (password for all: Passw0rd!)
-- =====================================================================
BEGIN;

INSERT INTO roles (role_name) VALUES ('Admin'), ('Procurement'), ('Logistics'), ('Analyst');

INSERT INTO users (email, password_hash, full_name, role_id) VALUES
 ('admin@scm.test',       crypt('Passw0rd!', gen_salt('bf')), 'Asha Admin',       1),
 ('procurement@scm.test', crypt('Passw0rd!', gen_salt('bf')), 'Pranav Procure',   2),
 ('logistics@scm.test',   crypt('Passw0rd!', gen_salt('bf')), 'Lakshmi Logistics',3),
 ('analyst@scm.test',     crypt('Passw0rd!', gen_salt('bf')), 'Arjun Analyst',    4);

INSERT INTO suppliers (name, country, contact_email, tier, onboarded_on) VALUES
 ('Shenzhen Microtech Co.',  'China',       'sales@szmicrotech.example',   1, CURRENT_DATE - 900),
 ('Bavaria Precision GmbH',  'Germany',     'orders@bavariaprec.example',  1, CURRENT_DATE - 700),
 ('Pune Components Pvt Ltd', 'India',       'sales@punecomp.example',      2, CURRENT_DATE - 400),
 ('Lone Star Plastics',      'USA',         'b2b@lonestarplastics.example',2, CURRENT_DATE - 300),
 ('Rotterdam Cooling BV',    'Netherlands', 'info@rotcooling.example',     3, CURRENT_DATE - 120);

INSERT INTO warehouses (name, city, country, capacity_units) VALUES
 ('Bengaluru Hub',       'Bengaluru', 'India',       200000),
 ('Rotterdam DC',        'Rotterdam', 'Netherlands', 150000),
 ('Dallas Fulfilment',   'Dallas',    'USA',         120000);

INSERT INTO products (sku, name, unit_of_measure) VALUES
 ('SKU-MCU-100',  'Microcontroller Unit',     'unit'),
 ('SKU-SENS-210', 'Temperature Sensor',       'unit'),
 ('SKU-PCB-330',  'PCB Board (4-layer)',      'unit'),
 ('SKU-HOUS-410', 'Polymer Housing',          'unit'),
 ('SKU-COOL-510', 'Cold-chain Cooling Unit',  'unit');

INSERT INTO supplier_products (supplier_id, product_id, unit_price, lead_time_days, available_stock) VALUES
 (1, 1,  4.20, 14,  50000),
 (1, 2,  2.60, 14,  80000),
 (2, 1,  4.90, 10,  20000),
 (2, 5, 92.00, 21,    500),
 (3, 3,  1.70, 12, 100000),
 (3, 4,  0.70, 12,  60000),
 (3, 2,  2.75, 12,  30000),
 (4, 4,  0.80,  7,  90000),
 (5, 5, 84.00, 30,    800);

INSERT INTO inventory (warehouse_id, product_id, quantity_on_hand, reorder_level) VALUES
 (1, 1, 1200,  2000),
 (1, 2,  500,  1000),
 (1, 3, 8000,  3000),
 (2, 5,   40,    50),
 (2, 1,  300,   500),
 (3, 4, 15000, 5000);

-- Purchase orders (created_by = 2, the Procurement user)
INSERT INTO purchase_orders (supplier_id, warehouse_id, created_by, status, order_date, expected_date) VALUES
 (1, 1, 2, 'Received',   CURRENT_DATE - 60, CURRENT_DATE - 40),   -- PO 1
 (1, 1, 2, 'Received',   CURRENT_DATE - 45, CURRENT_DATE - 28),   -- PO 2
 (2, 2, 2, 'In Transit', CURRENT_DATE - 20, CURRENT_DATE - 3),    -- PO 3
 (3, 1, 2, 'Received',   CURRENT_DATE - 35, CURRENT_DATE - 23),   -- PO 4
 (4, 3, 2, 'Cancelled',  CURRENT_DATE - 25, CURRENT_DATE - 15),   -- PO 5
 (5, 2, 2, 'In Transit', CURRENT_DATE - 12, CURRENT_DATE + 10),   -- PO 6
 (1, 1, 2, 'Placed',     CURRENT_DATE - 3,  CURRENT_DATE + 11);   -- PO 7

INSERT INTO po_items (po_id, product_id, quantity, unit_price) VALUES
 (1, 1,  5000,  4.20), (1, 2,  3000,  2.60),
 (2, 1,  4000,  4.20),
 (3, 1,  1000,  4.90), (3, 5,    20, 92.00),
 (4, 3, 10000,  1.70), (4, 4,  8000,  0.70),
 (5, 4, 20000,  0.80),
 (6, 5,    30, 84.00),
 (7, 2,  6000,  2.60);

UPDATE purchase_orders po
   SET total_amount = (SELECT COALESCE(SUM(quantity * unit_price), 0) FROM po_items i WHERE i.po_id = po.po_id);

-- Shipments
INSERT INTO shipments (po_id, carrier, tracking_no, vehicle_id, status, shipped_at, eta, delivered_at) VALUES
 (1, 'Maersk Land',   'TRK-0001-CN', 'TRUCK-CN-1021', 'Delivered',  now() - INTERVAL '58 days', now() - INTERVAL '42 days', now() - INTERVAL '38 days'), -- 4 days late
 (2, 'Maersk Land',   'TRK-0002-CN', 'TRUCK-CN-1022', 'Delivered',  now() - INTERVAL '43 days', now() - INTERVAL '30 days', now() - INTERVAL '30 days'), -- on time
 (3, 'Rhine Freight', 'TRK-0003-DE', 'TRUCK-DE-4417', 'In Transit', now() - INTERVAL '18 days', now() - INTERVAL '3 days',  NULL),
 (4, 'BlueDart Cargo','TRK-0004-IN', 'TRUCK-IN-7788', 'Delivered',  now() - INTERVAL '33 days', now() - INTERVAL '25 days', now() - INTERVAL '26 days'), -- early
 (6, 'NorthSea Lines','TRK-0006-NL', 'TRUCK-NL-3302', 'Delayed',    now() - INTERVAL '10 days', now() + INTERVAL '10 days', NULL);

-- Telemetry pings for shipment 3 -> trigger fires on the last row:
-- last moving ping = -10h, stationary ping at -5h => 5h > 4h => status 'Delayed' + log row.
INSERT INTO shipment_telemetry_pings (shipment_id, recorded_at, speed_kmh, latitude, longitude) VALUES
 (3, now() - INTERVAL '12 hours', 71.5, 50.4000, 8.2000),
 (3, now() - INTERVAL '10 hours', 58.0, 50.1109, 8.6821),
 (3, now() - INTERVAL '8 hours',   0.0, 50.1109, 8.6821),
 (3, now() - INTERVAL '5 hours',   0.0, 50.1109, 8.6821);

-- Risk documents: embeddings are NULL here; run embedding-service/seed_embeddings.py to fill them.
INSERT INTO risk_documents (doc_type, supplier_id, title, content, source_url, published_at) VALUES
 ('Contract', 1, 'Shenzhen Microtech master supply agreement',
  'Supplier must deliver microcontrollers within 14 days of order. Late delivery beyond 5 days triggers a 2% penalty per week. Force majeure includes port closures and government-ordered shutdowns. Either party may terminate with 90 days notice.',
  NULL, now() - INTERVAL '300 days'),
 ('Contract', 2, 'Bavaria Precision quality and delivery contract',
  'Cooling units shipped under refrigerated conditions not exceeding 6 degrees Celsius. Temperature excursions longer than 30 minutes allow the buyer to reject the lot. Carrier liability limited to invoice value.',
  NULL, now() - INTERVAL '200 days'),
 ('News', NULL, 'Port strike disrupts container traffic in Rotterdam',
  'A multi-day dockworker strike at the Port of Rotterdam has caused severe congestion, with vessels waiting up to five days for berths. Shippers expect delays across northern European routes and rising spot freight rates.',
  'https://news.example/rotterdam-strike', now() - INTERVAL '3 days'),
 ('News', 1, 'Typhoon warning halts Shenzhen Yantian terminal operations',
  'Authorities suspended loading operations at the Yantian terminal ahead of a typhoon. Electronics exporters in Shenzhen warn of two-week shipment backlogs and possible component shortages.',
  'https://news.example/yantian-typhoon', now() - INTERVAL '1 day');

COMMIT;

REFRESH MATERIALIZED VIEW vw_supplier_risk_summary;
