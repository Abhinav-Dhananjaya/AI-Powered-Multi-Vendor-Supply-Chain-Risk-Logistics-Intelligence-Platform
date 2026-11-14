-- =====================================================================
-- 002_logic.sql  |  Functions, triggers, materialized view
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Supplier risk score (0 = safe, 100 = critical), computed dynamically
--    score = 50*delay_rate + 25*cancel_rate + 25*min(avg_delay_days/7, 1)
--    No shipment history => neutral 50 (unknown risk is not "safe").
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_calculate_supplier_risk_score(p_supplier_id INT)
RETURNS NUMERIC(5,2)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ship_total   INT;
    v_ship_delayed INT;
    v_avg_delay    NUMERIC;
    v_po_total     INT;
    v_po_cancelled INT;
    v_score        NUMERIC;
BEGIN
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE s.status = 'Delayed'
                             OR (s.delivered_at IS NOT NULL AND s.eta IS NOT NULL AND s.delivered_at > s.eta)),
           AVG(EXTRACT(EPOCH FROM (s.delivered_at - s.eta)) / 86400.0)
               FILTER (WHERE s.delivered_at IS NOT NULL AND s.eta IS NOT NULL AND s.delivered_at > s.eta)
      INTO v_ship_total, v_ship_delayed, v_avg_delay
      FROM shipments s
      JOIN purchase_orders po ON po.po_id = s.po_id
     WHERE po.supplier_id = p_supplier_id;

    SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'Cancelled')
      INTO v_po_total, v_po_cancelled
      FROM purchase_orders WHERE supplier_id = p_supplier_id;

    IF v_ship_total = 0 AND v_po_total = 0 THEN
        RETURN 50.00;
    END IF;

    v_score := 50 * COALESCE(v_ship_delayed::NUMERIC / NULLIF(v_ship_total, 0), 0)
             + 25 * COALESCE(v_po_cancelled::NUMERIC / NULLIF(v_po_total, 0), 0)
             + 25 * LEAST(COALESCE(v_avg_delay, 0) / 7.0, 1);

    RETURN ROUND(LEAST(v_score, 100), 2);
END;
$$;

-- ---------------------------------------------------------------------
-- B. Materialized view: supplier metrics + shipment delay rate
--    Aggregates are built in separate CTEs to avoid join fan-out
--    (PO -> shipments would otherwise multiply total_spend).
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW vw_supplier_risk_summary AS
WITH po AS (
    SELECT supplier_id,
           COUNT(*)                                                      AS total_orders,
           COUNT(*) FILTER (WHERE status = 'Cancelled')                  AS cancelled_orders,
           COALESCE(SUM(total_amount) FILTER (WHERE status <> 'Cancelled'), 0) AS total_spend
      FROM purchase_orders
     GROUP BY supplier_id
), sh AS (
    SELECT p.supplier_id,
           COUNT(*) AS total_shipments,
           COUNT(*) FILTER (WHERE s.status = 'Delayed'
                             OR (s.delivered_at IS NOT NULL AND s.eta IS NOT NULL AND s.delivered_at > s.eta)) AS delayed_shipments,
           AVG(EXTRACT(EPOCH FROM (s.delivered_at - s.eta)) / 86400.0)
               FILTER (WHERE s.delivered_at IS NOT NULL AND s.eta IS NOT NULL AND s.delivered_at > s.eta)     AS avg_delay_days
      FROM shipments s
      JOIN purchase_orders p ON p.po_id = s.po_id
     GROUP BY p.supplier_id
)
SELECT sp.supplier_id,
       sp.name,
       sp.country,
       sp.tier,
       COALESCE(po.total_orders, 0)        AS total_orders,
       COALESCE(po.cancelled_orders, 0)    AS cancelled_orders,
       COALESCE(po.total_spend, 0)         AS total_spend,
       COALESCE(sh.total_shipments, 0)     AS total_shipments,
       COALESCE(sh.delayed_shipments, 0)   AS delayed_shipments,
       ROUND(100.0 * COALESCE(sh.delayed_shipments, 0) / NULLIF(sh.total_shipments, 0), 2) AS delay_rate_pct,
       ROUND(COALESCE(sh.avg_delay_days, 0)::NUMERIC, 2) AS avg_delay_days,
       fn_calculate_supplier_risk_score(sp.supplier_id)  AS risk_score,
       CASE
           WHEN fn_calculate_supplier_risk_score(sp.supplier_id) >= 60 THEN 'High'
           WHEN fn_calculate_supplier_risk_score(sp.supplier_id) >= 30 THEN 'Medium'
           ELSE 'Low'
       END AS risk_level
  FROM suppliers sp
  LEFT JOIN po ON po.supplier_id = sp.supplier_id
  LEFT JOIN sh ON sh.supplier_id = sp.supplier_id
 WHERE sp.is_active
WITH DATA;

-- Required for REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX uq_vw_supplier_risk_summary ON vw_supplier_risk_summary (supplier_id);
CREATE INDEX idx_vw_supplier_risk_score ON vw_supplier_risk_summary (risk_score DESC);

-- Refresh: REFRESH MATERIALIZED VIEW CONCURRENTLY vw_supplier_risk_summary;

-- ---------------------------------------------------------------------
-- C. Trigger: mark shipment 'Delayed' when speed = 0 for > 4 hours
--    Fires on every ping insert. If the new ping is stationary and the last
--    moving ping (or dispatch time) is more than 4h earlier, flag the shipment.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_flag_stalled_shipment()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_status      VARCHAR(20);
    v_shipped_at  TIMESTAMPTZ;
    v_last_moving TIMESTAMPTZ;
BEGIN
    IF NEW.speed_kmh <> 0 THEN
        RETURN NEW;
    END IF;

    -- lock the shipment row so concurrent pings cannot double-log
    SELECT status, shipped_at
      INTO v_status, v_shipped_at
      FROM shipments
     WHERE shipment_id = NEW.shipment_id
       FOR UPDATE;

    IF v_status IS DISTINCT FROM 'In Transit' THEN
        RETURN NEW;
    END IF;

    SELECT MAX(recorded_at)
      INTO v_last_moving
      FROM shipment_telemetry_pings
     WHERE shipment_id = NEW.shipment_id
       AND speed_kmh > 0
       AND recorded_at <= NEW.recorded_at;

    v_last_moving := COALESCE(v_last_moving, v_shipped_at);

    IF v_last_moving IS NOT NULL
       AND NEW.recorded_at - v_last_moving > INTERVAL '4 hours' THEN

        UPDATE shipments SET status = 'Delayed' WHERE shipment_id = NEW.shipment_id;

        INSERT INTO shipment_status_log (shipment_id, old_status, new_status, reason)
        VALUES (NEW.shipment_id, 'In Transit', 'Delayed',
                format('Stationary (speed=0) since %s; %s elapsed',
                       v_last_moving, NEW.recorded_at - v_last_moving));
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_flag_stalled_shipment
AFTER INSERT ON shipment_telemetry_pings
FOR EACH ROW EXECUTE FUNCTION fn_flag_stalled_shipment();

-- ---------------------------------------------------------------------
-- D. Atomic order placement: create PO + items and DEDUCT vendor stock.
--    Any failure raises -> caller's transaction rolls back everything.
--    Custom SQLSTATE 'PS001' = insufficient stock (mapped to HTTP 409 by the API).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_place_purchase_order(
    p_supplier_id  INT,
    p_warehouse_id INT,
    p_user_id      INT,
    p_items        JSONB          -- [{"productId":1,"quantity":100}, ...]
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_po_id    BIGINT;
    v_item     RECORD;
    v_price    NUMERIC(12,2);
    v_lead     SMALLINT;
    v_max_lead SMALLINT := 1;
BEGIN
    IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_ORDER: at least one item is required';
    END IF;

    PERFORM 1 FROM suppliers WHERE supplier_id = p_supplier_id AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_INACTIVE: supplier % not found or inactive', p_supplier_id;
    END IF;

    INSERT INTO purchase_orders (supplier_id, warehouse_id, created_by, status, order_date, expected_date)
    VALUES (p_supplier_id, p_warehouse_id, p_user_id, 'Placed', CURRENT_DATE, CURRENT_DATE + 1)
    RETURNING po_id INTO v_po_id;

    FOR v_item IN
        SELECT (e->>'productId')::INT AS product_id, (e->>'quantity')::INT AS qty
          FROM jsonb_array_elements(p_items) AS e
         ORDER BY 1                       -- consistent lock order avoids deadlocks
    LOOP
        -- conditional decrement: row lock + stock check in one atomic statement
        UPDATE supplier_products sp
           SET available_stock = sp.available_stock - v_item.qty
         WHERE sp.supplier_id = p_supplier_id
           AND sp.product_id  = v_item.product_id
           AND sp.available_stock >= v_item.qty
        RETURNING sp.unit_price, sp.lead_time_days INTO v_price, v_lead;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'INSUFFICIENT_STOCK: supplier % cannot supply % x product %',
                  p_supplier_id, v_item.qty, v_item.product_id
                  USING ERRCODE = 'PS001';
        END IF;

        INSERT INTO po_items (po_id, product_id, quantity, unit_price)
        VALUES (v_po_id, v_item.product_id, v_item.qty, v_price);

        v_max_lead := GREATEST(v_max_lead, v_lead);
    END LOOP;

    UPDATE purchase_orders po
       SET total_amount  = (SELECT SUM(quantity * unit_price) FROM po_items WHERE po_id = v_po_id),
           expected_date = CURRENT_DATE + v_max_lead
     WHERE po.po_id = v_po_id;

    RETURN v_po_id;
END;
$$;

-- ---------------------------------------------------------------------
-- E. Goods receipt: mark PO received and add stock to the warehouse
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_receive_purchase_order(p_po_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE v_wh INT;
BEGIN
    UPDATE purchase_orders SET status = 'Received'
     WHERE po_id = p_po_id AND status IN ('Placed','Confirmed','In Transit')
    RETURNING warehouse_id INTO v_wh;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO % cannot be received in its current state', p_po_id;
    END IF;

    INSERT INTO inventory (warehouse_id, product_id, quantity_on_hand)
    SELECT v_wh, product_id, quantity FROM po_items WHERE po_id = p_po_id
    ON CONFLICT (warehouse_id, product_id)
    DO UPDATE SET quantity_on_hand = inventory.quantity_on_hand + EXCLUDED.quantity_on_hand,
                  updated_at = now();
END;
$$;
