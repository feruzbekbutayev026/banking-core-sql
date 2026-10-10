-- =====================================================================
-- Core Banking Ledger — Schema
-- Double-entry bookkeeping, immutable ledger, audit trail
-- PostgreSQL 14+
-- =====================================================================
DROP SCHEMA IF EXISTS bank CASCADE;
CREATE SCHEMA bank;
SET search_path TO bank;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE account_status AS ENUM ('active', 'frozen', 'closed');
CREATE TYPE txn_kind       AS ENUM ('deposit', 'withdrawal', 'transfer', 'fee', 'interest');

CREATE TABLE currencies (
    code        CHAR(3) PRIMARY KEY,
    name        TEXT    NOT NULL,
    minor_units SMALLINT NOT NULL DEFAULT 2
);

CREATE TABLE customers (
    customer_id  BIGSERIAL PRIMARY KEY,
    full_name    TEXT NOT NULL,
    national_id  TEXT NOT NULL UNIQUE,
    phone        TEXT,
    risk_level   SMALLINT NOT NULL DEFAULT 1 CHECK (risk_level BETWEEN 1 AND 5),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
    account_id     BIGSERIAL PRIMARY KEY,
    iban           TEXT           NOT NULL UNIQUE,
    customer_id    BIGINT         REFERENCES customers(customer_id),   -- NULL = internal bank account
    currency       CHAR(3)        NOT NULL REFERENCES currencies(code),
    status         account_status NOT NULL DEFAULT 'active',
    overdraft_limit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (overdraft_limit >= 0),
    balance        NUMERIC(18,2)  NOT NULL DEFAULT 0,      -- cached; ledger is the source of truth
    daily_limit    NUMERIC(18,2)  NOT NULL DEFAULT 10000,
    opened_at      TIMESTAMPTZ    NOT NULL DEFAULT now(),
    version        BIGINT         NOT NULL DEFAULT 0,      -- optimistic locking
    CONSTRAINT balance_within_overdraft CHECK (balance >= -overdraft_limit OR customer_id IS NULL)
);

-- A business transaction (one transfer = one row here, two+ ledger entries)
CREATE TABLE transactions (
    txn_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            txn_kind    NOT NULL,
    idempotency_key TEXT        UNIQUE,                     -- safe client retries
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Double-entry ledger: every txn's entries must sum to zero
CREATE TABLE ledger_entries (
    entry_id    BIGSERIAL PRIMARY KEY,
    txn_id      UUID          NOT NULL REFERENCES transactions(txn_id),
    account_id  BIGINT        NOT NULL REFERENCES accounts(account_id),
    amount      NUMERIC(18,2) NOT NULL CHECK (amount <> 0),  -- + credit / - debit
    balance_after NUMERIC(18,2) NOT NULL,
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX idx_ledger_account_time ON ledger_entries (account_id, created_at DESC);
CREATE INDEX idx_ledger_txn          ON ledger_entries (txn_id);

CREATE TABLE audit_log (
    audit_id    BIGSERIAL PRIMARY KEY,
    table_name  TEXT        NOT NULL,
    row_pk      TEXT        NOT NULL,
    action      TEXT        NOT NULL,
    old_data    JSONB,
    new_data    JSONB,
    changed_by  TEXT        NOT NULL DEFAULT current_user,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
