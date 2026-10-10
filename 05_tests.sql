-- =====================================================================
-- Self-checking test suite (run with: psql -v ON_ERROR_STOP=1 -f 05_tests.sql)
-- Each test raises an exception on failure.
-- =====================================================================
SET search_path TO bank;

CREATE OR REPLACE FUNCTION assert(cond BOOLEAN, msg TEXT) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT cond THEN RAISE EXCEPTION 'TEST FAILED: %', msg; END IF;
    RAISE NOTICE 'ok - %', msg;
END $$;

DO $$
DECLARE
    a BIGINT; b BIGINT; k TEXT := 'test-' || gen_random_uuid(); t1 UUID; t2 UUID; bal_a NUMERIC; bal_b NUMERIC; fee_bal NUMERIC;
BEGIN
    SELECT account_id INTO a FROM accounts WHERE iban = 'UZ0010USD';
    SELECT account_id INTO b FROM accounts WHERE iban = 'UZ0020USD';
    SELECT balance INTO bal_a FROM accounts WHERE account_id = a;
    SELECT balance INTO bal_b FROM accounts WHERE account_id = b;
    SELECT balance INTO fee_bal FROM accounts WHERE iban = 'FEE-USD';

    -- 1. Successful transfer with fee
    t1 := transfer(a, b, 100, k, 'Unit test');
    PERFORM assert((SELECT balance FROM accounts WHERE account_id = a) = bal_a - 101, 'sender debited amount + 1.00 fee');
    PERFORM assert((SELECT balance FROM accounts WHERE account_id = b) = bal_b + 100, 'receiver credited');
    PERFORM assert((SELECT balance FROM accounts WHERE iban = 'FEE-USD') = fee_bal + 1, 'fee account credited');

    -- 2. Idempotency
    t2 := transfer(a, b, 100, k, 'Retry');
    PERFORM assert(t1 = t2, 'retry with same idempotency key returns same txn');
    PERFORM assert((SELECT balance FROM accounts WHERE account_id = a) = bal_a - 101, 'retry did not double-charge');

    -- 3. Insufficient funds
    BEGIN
        PERFORM transfer(a, b, 1000000);
        PERFORM assert(false, 'overdraft should be rejected');
    EXCEPTION WHEN raise_exception THEN
        PERFORM assert(SQLERRM LIKE 'Insufficient funds%' OR SQLERRM LIKE 'Daily limit%', 'large transfer rejected');
    END;

    -- 4. Currency mismatch
    BEGIN
        PERFORM transfer(a, (SELECT account_id FROM accounts WHERE iban = 'UZ0020UZS'), 10);
        PERFORM assert(false, 'currency mismatch should be rejected');
    EXCEPTION WHEN raise_exception THEN
        PERFORM assert(SQLERRM LIKE 'Currency mismatch%', 'currency mismatch rejected');
    END;

    -- 5. Frozen account
    UPDATE accounts SET status = 'frozen' WHERE account_id = b;
    BEGIN
        PERFORM transfer(a, b, 10);
        PERFORM assert(false, 'frozen account should be rejected');
    EXCEPTION WHEN raise_exception THEN
        PERFORM assert(SQLERRM LIKE 'Both accounts must be active%', 'transfer to frozen account rejected');
    END;
    UPDATE accounts SET status = 'active' WHERE account_id = b;
    PERFORM assert((SELECT count(*) FROM audit_log WHERE table_name = 'accounts' AND row_pk = b::text AND action = 'UPDATE') >= 2,
                   'status changes captured in audit_log');

    -- 6. Ledger immutability
    BEGIN
        UPDATE ledger_entries SET amount = 1 WHERE txn_id = t1;
        PERFORM assert(false, 'ledger update should fail');
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM assert(true, 'ledger is append-only');
    END;
END $$;

-- 7. Unbalanced manual posting is rejected at COMMIT (deferred constraint trigger)
DO $$
DECLARE t UUID;
BEGIN
    INSERT INTO transactions (kind, description) VALUES ('fee', 'bad') RETURNING txn_id INTO t;
    INSERT INTO ledger_entries (txn_id, account_id, amount, balance_after) VALUES (t, 1, 5, 0);
    SET CONSTRAINTS ledger_balanced IMMEDIATE;
    PERFORM assert(false, 'unbalanced txn should fail');
EXCEPTION WHEN raise_exception THEN
    PERFORM assert(SQLERRM LIKE '%unbalanced%', 'unbalanced transaction rejected');
END $$;

-- 8. Global invariants
SELECT assert((SELECT sum(amount) FROM ledger_entries) = 0, 'whole ledger sums to zero');
SELECT assert(NOT EXISTS (SELECT 1 FROM v_reconciliation), 'cached balances match ledger');

-- 9. Row-level security
SET ROLE bank_app;
SET app.customer_id = '10';
SELECT assert((SELECT count(*) FROM accounts) = 2, 'app user sees only own 2 accounts');
SELECT assert((SELECT bool_and(account_id IN (SELECT account_id FROM accounts)) FROM ledger_entries), 'app user sees only own ledger');
RESET ROLE;

-- 10. Interest accrual keeps ledger balanced
CALL accrue_interest(0.06);
SELECT assert((SELECT sum(amount) FROM ledger_entries) = 0, 'ledger balanced after interest');

SELECT * FROM account_statement((SELECT account_id FROM accounts WHERE iban = 'UZ0010USD'), CURRENT_DATE, CURRENT_DATE);
