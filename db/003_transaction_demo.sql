-- =====================================================================
-- 003_transaction_demo.sql  |  BEGIN / SAVEPOINT / COMMIT / ROLLBACK
--
-- Important PostgreSQL fact: PL/pgSQL does NOT allow SAVEPOINT statements.
-- Inside a function/DO block, a `BEGIN ... EXCEPTION ... END` block *is* an
-- implicit savepoint (sub-transaction). So this file shows both styles:
--   Part 1: explicit SQL-level transaction control (psql / application code)
--   Part 2: PL/pgSQL block using exception blocks (implicit savepoints)
-- Run after 004_seed.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Part 1: explicit transaction with SAVEPOINT (run in psql)
-- Order 1: supplier 3, 2 lines (valid)  -> kept
-- Order 2: supplier 3, impossible qty   -> rolled back to savepoint only
-- ---------------------------------------------------------------------
BEGIN;

    SELECT fn_place_purchase_order(3, 1, 2,
        '[{"productId":3,"quantity":500},{"productId":4,"quantity":200}]'::jsonb) AS first_po;

    SAVEPOINT before_second_order;

    -- This raises PS001 (insufficient stock). The transaction is now in an
    -- aborted state until we roll back to the savepoint.
    SELECT fn_place_purchase_order(3, 1, 2,
        '[{"productId":3,"quantity":999999999}]'::jsonb) AS second_po;

    ROLLBACK TO SAVEPOINT before_second_order;   -- undoes only the failed order

    -- first order is still intact here
    SELECT po_id, status, total_amount FROM purchase_orders ORDER BY po_id DESC LIMIT 1;

COMMIT;     -- use ROLLBACK; instead to discard everything including the first order

-- ---------------------------------------------------------------------
-- Part 2: PL/pgSQL block. Each inner BEGIN..EXCEPTION..END is a savepoint.
-- A failed order does not abort the whole batch.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_po_id   BIGINT;
    v_batch   JSONB[] := ARRAY[
        '[{"productId":1,"quantity":100}]'::jsonb,        -- ok
        '[{"productId":1,"quantity":999999999}]'::jsonb,  -- fails: stock
        '[{"productId":2,"quantity":50}]'::jsonb          -- ok
    ];
    v_items   JSONB;
BEGIN
    FOREACH v_items IN ARRAY v_batch LOOP
        BEGIN                                   -- implicit SAVEPOINT
            v_po_id := fn_place_purchase_order(1, 1, 2, v_items);
            RAISE NOTICE 'PO % placed', v_po_id;
        EXCEPTION
            WHEN SQLSTATE 'PS001' THEN          -- implicit ROLLBACK TO SAVEPOINT
                RAISE NOTICE 'Skipped order (insufficient stock): %', SQLERRM;
            WHEN OTHERS THEN
                RAISE NOTICE 'Skipped order (%): %', SQLSTATE, SQLERRM;
        END;
    END LOOP;
    -- COMMIT happens when the DO statement's surrounding transaction commits.
END;
$$;

-- Verify atomicity: stock only dropped for orders that exist
SELECT sp.supplier_id, sp.product_id, sp.available_stock
FROM supplier_products sp WHERE sp.supplier_id = 1;
