-- =====================================================================
-- 005_queries.sql  |  Five showcase queries
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q1. Deep JOIN (7 tables): full order line view with supplier, warehouse,
--     buyer, product and shipment status
-- ---------------------------------------------------------------------
SELECT po.po_id,
       po.order_date,
       s.name                    AS supplier,
       w.name                    AS warehouse,
       u.full_name               AS buyer,
       p.sku,
       pi.quantity,
       pi.unit_price,
       (pi.quantity * pi.unit_price) AS line_total,
       COALESCE(sh.status, 'No shipment') AS shipment_status,
       sh.eta
  FROM purchase_orders po
  JOIN suppliers   s  ON s.supplier_id  = po.supplier_id
  JOIN warehouses  w  ON w.warehouse_id = po.warehouse_id
  JOIN users       u  ON u.user_id      = po.created_by
  JOIN po_items    pi ON pi.po_id       = po.po_id
  JOIN products    p  ON p.product_id   = pi.product_id
  LEFT JOIN shipments sh ON sh.po_id    = po.po_id
 ORDER BY po.po_id, p.sku;

-- ---------------------------------------------------------------------
-- Q2. Vendor reliability scoring with GROUP BY + HAVING
--     Suppliers with >= 1 shipment and on-time rate below 100%, worst first
-- ---------------------------------------------------------------------
SELECT s.supplier_id,
       s.name,
       COUNT(sh.shipment_id) AS shipments,
       COUNT(*) FILTER (WHERE sh.status = 'Delayed'
                         OR (sh.delivered_at IS NOT NULL AND sh.delivered_at > sh.eta)) AS late_shipments,
       ROUND(100.0 * COUNT(*) FILTER (WHERE sh.status <> 'Delayed'
                         AND NOT (sh.delivered_at IS NOT NULL AND sh.delivered_at > sh.eta))
             / COUNT(sh.shipment_id), 1) AS on_time_pct,
       ROUND(AVG(EXTRACT(EPOCH FROM (sh.delivered_at - sh.eta)) / 86400.0)
             FILTER (WHERE sh.delivered_at > sh.eta)::NUMERIC, 2) AS avg_days_late
  FROM suppliers s
  JOIN purchase_orders po ON po.supplier_id = s.supplier_id
  JOIN shipments sh       ON sh.po_id       = po.po_id
 GROUP BY s.supplier_id, s.name
HAVING COUNT(sh.shipment_id) >= 1
   AND COUNT(*) FILTER (WHERE sh.status = 'Delayed'
                         OR (sh.delivered_at IS NOT NULL AND sh.delivered_at > sh.eta)) > 0
 ORDER BY on_time_pct ASC, late_shipments DESC;

-- ---------------------------------------------------------------------
-- Q3. Subqueries: open orders that are high risk
--     (supplier risk >= 40  OR  a delayed shipment)  — shows value vs. average
-- ---------------------------------------------------------------------
SELECT po.po_id,
       s.name AS supplier,
       po.status,
       po.total_amount,
       ROUND(po.total_amount /
             (SELECT AVG(total_amount) FROM purchase_orders WHERE status <> 'Cancelled'), 2) AS x_avg_order_value,
       (SELECT r.risk_score FROM vw_supplier_risk_summary r WHERE r.supplier_id = po.supplier_id) AS supplier_risk_score,
       EXISTS (SELECT 1 FROM shipments sh
                WHERE sh.po_id = po.po_id AND sh.status = 'Delayed') AS has_delayed_shipment
  FROM purchase_orders po
  JOIN suppliers s ON s.supplier_id = po.supplier_id
 WHERE po.status IN ('Placed','Confirmed','In Transit')
   AND ( po.supplier_id IN (SELECT supplier_id FROM vw_supplier_risk_summary WHERE risk_score >= 40)
         OR EXISTS (SELECT 1 FROM shipments sh WHERE sh.po_id = po.po_id AND sh.status = 'Delayed') )
 ORDER BY supplier_risk_score DESC NULLS LAST, po.total_amount DESC;

-- ---------------------------------------------------------------------
-- Q4. Inventory gap analysis: products at/below reorder level and whether
--     inbound open POs will cover the gap (CTE + aggregate + JOIN)
-- ---------------------------------------------------------------------
WITH inbound AS (
    SELECT po.warehouse_id, pi.product_id, SUM(pi.quantity) AS inbound_qty
      FROM purchase_orders po
      JOIN po_items pi ON pi.po_id = po.po_id
     WHERE po.status IN ('Placed','Confirmed','In Transit')
     GROUP BY po.warehouse_id, pi.product_id
)
SELECT w.name AS warehouse,
       p.sku,
       i.quantity_on_hand,
       i.reorder_level,
       COALESCE(ib.inbound_qty, 0) AS inbound_qty,
       i.quantity_on_hand + COALESCE(ib.inbound_qty, 0) - i.reorder_level AS projected_surplus,
       CASE WHEN i.quantity_on_hand + COALESCE(ib.inbound_qty, 0) < i.reorder_level
            THEN 'REORDER NOW' ELSE 'Covered by inbound' END AS action
  FROM inventory i
  JOIN warehouses w ON w.warehouse_id = i.warehouse_id
  JOIN products   p ON p.product_id   = i.product_id
  LEFT JOIN inbound ib ON ib.warehouse_id = i.warehouse_id AND ib.product_id = i.product_id
 WHERE i.quantity_on_hand <= i.reorder_level
 ORDER BY projected_surplus;

-- ---------------------------------------------------------------------
-- Q5. Vector search: top-5 documents by cosine distance.
--     $1 = 384-d query embedding from the FastAPI service, passed as text
--     like '[0.01,-0.02,...]' and cast with ::vector.
--     similarity = 1 - cosine_distance
-- ---------------------------------------------------------------------
SELECT d.doc_id,
       d.doc_type,
       d.title,
       s.name AS supplier,
       1 - (d.embedding <=> $1::vector) AS similarity,
       left(d.content, 160)             AS snippet
  FROM risk_documents d
  LEFT JOIN suppliers s ON s.supplier_id = d.supplier_id
 WHERE d.embedding IS NOT NULL
 ORDER BY d.embedding <=> $1::vector      -- uses idx_risk_docs_embedding_hnsw
 LIMIT 5;

-- Q5b. "Find documents similar to an existing one" — no external embedding needed (runnable as-is)
SELECT d2.doc_id, d2.title, 1 - (d2.embedding <=> d1.embedding) AS similarity
  FROM risk_documents d1
  JOIN LATERAL (
        SELECT * FROM risk_documents x
         WHERE x.doc_id <> d1.doc_id AND x.embedding IS NOT NULL
         ORDER BY x.embedding <=> d1.embedding
         LIMIT 3) d2 ON TRUE
 WHERE d1.doc_id = 3 AND d1.embedding IS NOT NULL;
