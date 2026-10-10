-- =====================================================================
-- Business logic: triggers, procedures, functions
-- =====================================================================
SET search_path TO bank;

-- ---------------------------------------------------------------------
-- 1. Ledger is append-only
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_ledger_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'ledger_entries is append-only (% not allowed)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END $$;

CREATE TRIGGER ledger_no_update_delete
BEFORE UPDATE OR DELETE ON ledger_entries
FOR EACH ROW EXECUTE FUNCTION trg_ledger_immutable();

-- ---------------------------------------------------------------------
-- 2. Double-entry invariant, checked at COMMIT (deferred constraint trigger)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_check_txn_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s NUMERIC;
BEGIN
    SELECT sum(amount) INTO s FROM ledger_entries WHERE txn_id = NEW.txn_id;
    IF s <> 0 THEN
        RAISE EXCEPTION 'Transaction % is unbalanced (sum = %)', NEW.txn_id, s;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ledger_balanced
AFTER INSERT ON ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION trg_check_txn_balanced();

-- ---------------------------------------------------------------------
-- 3. Generic JSONB audit trigger for accounts & customers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE pk TEXT;
BEGIN
    -- TG_ARGV[0] = name of the primary-key column
    pk := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END ->> TG_ARGV[0];
    INSERT INTO audit_log (table_name, row_pk, action, old_data, new_data)
    VALUES (TG_TABLE_NAME, pk, TG_OP,
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
    RETURN NULL;
END $$;

-- Skip pure balance/version changes on accounts to keep the log readable
CREATE TRIGGER audit_accounts
AFTER INSERT OR DELETE OR UPDATE OF status, overdraft_limit, daily_limit ON accounts
FOR EACH ROW EXECUTE FUNCTION trg_audit('account_id');

CREATE TRIGGER audit_customers
AFTER INSERT OR UPDATE OR DELETE ON customers
FOR EACH ROW EXECUTE FUNCTION trg_audit('customer_id');

-- ---------------------------------------------------------------------
-- 4. Internal helper: post one ledger leg and update cached balance
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_entry(p_txn UUID, p_account BIGINT, p_amount NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE new_bal NUMERIC;
BEGIN
    UPDATE accounts
       SET balance = balance + p_amount, version = version + 1
     WHERE account_id = p_account
    RETURNING balance INTO new_bal;

    INSERT INTO ledger_entries (txn_id, account_id, amount, balance_after)
    VALUES (p_txn, p_account, p_amount, new_bal);
    RETURN new_bal;
END $$;

-- ---------------------------------------------------------------------
-- 5. Transfer: deadlock-safe locking, limits, idempotency, fees
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer(
    p_from        BIGINT,
    p_to          BIGINT,
    p_amount      NUMERIC,
    p_idem_key    TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
    v_txn      UUID;
    v_from     accounts%ROWTYPE;
    v_to       accounts%ROWTYPE;
    v_fee      NUMERIC := 0;
    v_fee_acct BIGINT;
    v_today    NUMERIC;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    IF p_from = p_to  THEN RAISE EXCEPTION 'Cannot transfer to the same account'; END IF;

    -- Idempotency: return the original transaction on retry
    IF p_idem_key IS NOT NULL THEN
        SELECT txn_id INTO v_txn FROM transactions WHERE idempotency_key = p_idem_key;
        IF FOUND THEN RETURN v_txn; END IF;
    END IF;

    -- Lock both rows in a consistent order to avoid deadlocks
    PERFORM 1 FROM accounts WHERE account_id IN (p_from, p_to) ORDER BY account_id FOR UPDATE;
    SELECT * INTO v_from FROM accounts WHERE account_id = p_from;
    SELECT * INTO v_to   FROM accounts WHERE account_id = p_to;

    IF v_from.account_id IS NULL OR v_to.account_id IS NULL THEN
        RAISE EXCEPTION 'Account not found';
    END IF;
    IF v_from.status <> 'active' OR v_to.status <> 'active' THEN
        RAISE EXCEPTION 'Both accounts must be active';
    END IF;
    IF v_from.currency <> v_to.currency THEN
        RAISE EXCEPTION 'Currency mismatch: % -> %', v_from.currency, v_to.currency;
    END IF;

    -- Fee: 0.5% for transfers to other customers, min 1, max 50
    IF v_from.customer_id IS DISTINCT FROM v_to.customer_id THEN
        v_fee := LEAST(GREATEST(round(p_amount * 0.005, 2), 1), 50);
        SELECT account_id INTO v_fee_acct FROM accounts
         WHERE customer_id IS NULL AND currency = v_from.currency AND iban LIKE 'FEE%';
    END IF;

    -- Daily outgoing limit
    SELECT COALESCE(-sum(amount), 0) INTO v_today
      FROM ledger_entries
     WHERE account_id = p_from AND amount < 0 AND created_at >= date_trunc('day', now());
    IF v_today + p_amount + v_fee > v_from.daily_limit THEN
        RAISE EXCEPTION 'Daily limit exceeded (used %, limit %)', v_today, v_from.daily_limit;
    END IF;

    IF v_from.balance - p_amount - v_fee < -v_from.overdraft_limit THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, requested %', v_from.balance, p_amount + v_fee;
    END IF;

    INSERT INTO transactions (kind, idempotency_key, description)
    VALUES ('transfer', p_idem_key, p_description)
    RETURNING txn_id INTO v_txn;

    PERFORM post_entry(v_txn, p_from, -p_amount);
    PERFORM post_entry(v_txn, p_to,    p_amount);

    IF v_fee > 0 THEN
        PERFORM post_entry(v_txn, p_from,     -v_fee);
        PERFORM post_entry(v_txn, v_fee_acct,  v_fee);
    END IF;

    RETURN v_txn;
END $$;

-- ---------------------------------------------------------------------
-- 6. Cash deposit / withdrawal against the bank's cash (vault) account
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cash_operation(p_account BIGINT, p_amount NUMERIC, p_kind txn_kind)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_txn UUID; v_vault BIGINT; v_acc accounts%ROWTYPE;
BEGIN
    IF p_kind NOT IN ('deposit','withdrawal') THEN RAISE EXCEPTION 'Invalid kind %', p_kind; END IF;
    SELECT * INTO v_acc FROM accounts WHERE account_id = p_account FOR UPDATE;
    IF v_acc.status <> 'active' THEN RAISE EXCEPTION 'Account is %', v_acc.status; END IF;

    SELECT account_id INTO v_vault FROM accounts
     WHERE customer_id IS NULL AND currency = v_acc.currency AND iban LIKE 'VAULT%';

    INSERT INTO transactions (kind, description) VALUES (p_kind, initcap(p_kind::text))
    RETURNING txn_id INTO v_txn;

    IF p_kind = 'deposit' THEN
        PERFORM post_entry(v_txn, p_account,  p_amount);
        PERFORM post_entry(v_txn, v_vault,   -p_amount);
    ELSE
        PERFORM post_entry(v_txn, p_account, -p_amount);   -- CHECK constraint enforces overdraft
        PERFORM post_entry(v_txn, v_vault,    p_amount);
    END IF;
    RETURN v_txn;
END $$;

-- ---------------------------------------------------------------------
-- 7. Monthly interest accrual (procedure with COMMIT per batch)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE accrue_interest(p_annual_rate NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_txn UUID; v_int NUMERIC; v_vault BIGINT; n INT := 0;
BEGIN
    FOR r IN SELECT account_id, balance, currency FROM accounts
              WHERE customer_id IS NOT NULL AND status = 'active' AND balance > 0
    LOOP
        v_int := round(r.balance * p_annual_rate / 12, 2);
        CONTINUE WHEN v_int <= 0;
        SELECT account_id INTO v_vault FROM accounts
         WHERE customer_id IS NULL AND currency = r.currency AND iban LIKE 'VAULT%';
        INSERT INTO transactions (kind, description) VALUES ('interest', 'Monthly interest')
        RETURNING txn_id INTO v_txn;
        PERFORM post_entry(v_txn, r.account_id, v_int);
        PERFORM post_entry(v_txn, v_vault,     -v_int);
        n := n + 1;
        IF n % 500 = 0 THEN COMMIT; END IF;
    END LOOP;
    RAISE NOTICE 'Interest posted to % accounts', n;
END $$;

-- ---------------------------------------------------------------------
-- 8. Statement & reconciliation
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION account_statement(p_account BIGINT, p_from DATE, p_to DATE)
RETURNS TABLE (posted_at TIMESTAMPTZ, kind txn_kind, description TEXT,
               debit NUMERIC, credit NUMERIC, balance NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT le.created_at, t.kind, t.description,
           CASE WHEN le.amount < 0 THEN -le.amount END,
           CASE WHEN le.amount > 0 THEN  le.amount END,
           le.balance_after
    FROM ledger_entries le JOIN transactions t USING (txn_id)
    WHERE le.account_id = p_account
      AND le.created_at >= p_from AND le.created_at < p_to + 1
    ORDER BY le.entry_id;
$$;

-- Any row returned = cached balance drifted from ledger (should be empty)
CREATE OR REPLACE VIEW v_reconciliation AS
SELECT a.account_id, a.iban, a.balance AS cached_balance,
       COALESCE(sum(le.amount), 0) AS ledger_balance
FROM accounts a LEFT JOIN ledger_entries le USING (account_id)
GROUP BY a.account_id
HAVING a.balance <> COALESCE(sum(le.amount), 0);
