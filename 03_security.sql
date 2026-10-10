-- =====================================================================
-- Roles & Row-Level Security
--   teller   : can run cash operations and transfers, read everything
--   auditor  : read-only, including audit_log
--   app_user : a customer-facing API role; sees only its own accounts
-- =====================================================================
SET search_path TO bank;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bank_teller')  THEN CREATE ROLE bank_teller;  END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bank_auditor') THEN CREATE ROLE bank_auditor; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bank_app')     THEN CREATE ROLE bank_app;     END IF;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA bank FROM PUBLIC;
GRANT USAGE ON SCHEMA bank TO bank_teller, bank_auditor, bank_app;

-- Auditor: read-only
GRANT SELECT ON ALL TABLES IN SCHEMA bank TO bank_auditor;

-- Teller: reads + business functions only (no direct writes to the ledger)
GRANT SELECT ON accounts, customers, transactions, ledger_entries TO bank_teller;
ALTER FUNCTION transfer(BIGINT, BIGINT, NUMERIC, TEXT, TEXT) SECURITY DEFINER;
ALTER FUNCTION cash_operation(BIGINT, NUMERIC, txn_kind)     SECURITY DEFINER;
ALTER FUNCTION transfer(BIGINT, BIGINT, NUMERIC, TEXT, TEXT) SET search_path = bank, pg_temp;
ALTER FUNCTION cash_operation(BIGINT, NUMERIC, txn_kind)     SET search_path = bank, pg_temp;
REVOKE EXECUTE ON FUNCTION transfer(BIGINT, BIGINT, NUMERIC, TEXT, TEXT), cash_operation(BIGINT, NUMERIC, txn_kind) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION transfer(BIGINT, BIGINT, NUMERIC, TEXT, TEXT), cash_operation(BIGINT, NUMERIC, txn_kind) TO bank_teller;

-- App: row-level security keyed by a session variable set by the API layer
--   SET app.customer_id = '42';
GRANT SELECT ON accounts, ledger_entries TO bank_app;

ALTER TABLE accounts       ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY staff_all_accounts ON accounts       TO bank_teller, bank_auditor USING (true);
CREATE POLICY staff_all_ledger   ON ledger_entries TO bank_teller, bank_auditor USING (true);

CREATE POLICY own_accounts ON accounts TO bank_app
    USING (customer_id = current_setting('app.customer_id', true)::bigint);

CREATE POLICY own_ledger ON ledger_entries TO bank_app
    USING (account_id IN (SELECT account_id FROM accounts
                          WHERE customer_id = current_setting('app.customer_id', true)::bigint));
