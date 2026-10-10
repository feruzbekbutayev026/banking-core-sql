# Core Banking Ledger in SQL

A production-style banking core written in **PostgreSQL / PL/pgSQL**: double-entry bookkeeping, safe money transfers, an immutable ledger, auditing, role-based access with row-level security — and a self-checking test suite.

## Features

- **Double-entry ledger** — every transaction's entries must sum to zero, enforced by a `DEFERRABLE INITIALLY DEFERRED` constraint trigger checked at commit.
- **Append-only ledger** — `UPDATE`/`DELETE` on `ledger_entries` is blocked by a trigger.
- **Safe transfers** (`transfer()`):
  - deadlock-free row locking (`SELECT ... ORDER BY id FOR UPDATE`)
  - idempotency keys for safe client retries
  - currency checks, account status checks, overdraft and daily limits
  - tiered fee (0.5%, min 1, max 50) posted to an internal fee account
- **Cash operations** against internal vault accounts.
- **Interest accrual** procedure with batched `COMMIT`s.
- **JSONB audit log** via one generic trigger (`trg_audit`) reused across tables.
- **Security** — `bank_teller`, `bank_auditor`, `bank_app` roles; `SECURITY DEFINER` functions with pinned `search_path`; RLS so an API user only sees its own accounts (`SET app.customer_id = '42'`).
- **Reconciliation view** that flags any drift between cached balances and the ledger.

## Structure

```
01_schema.sql    -- tables, enums, constraints, indexes
02_logic.sql     -- triggers, transfer(), cash_operation(), accrue_interest(), statements
03_security.sql  -- roles, grants, row-level security
04_seed.sql      -- 200 customers, 400 accounts, deposits and ~300 transfers
05_tests.sql     -- 16 assertions
```

## Run it

Requires PostgreSQL 14+ and a role that can `CREATE ROLE` (for `03_security.sql`).

```bash
createdb bank
for f in 0*.sql; do psql -d bank -v ON_ERROR_STOP=1 -f "$f"; done
```

Expected test output:

```
NOTICE:  ok - sender debited amount + 1.00 fee
NOTICE:  ok - retry with same idempotency key returns same txn
NOTICE:  ok - transfer to frozen account rejected
NOTICE:  ok - ledger is append-only
NOTICE:  ok - unbalanced transaction rejected
NOTICE:  ok - whole ledger sums to zero
NOTICE:  ok - app user sees only own 2 accounts
...
```

## Example

```sql
SET search_path TO bank;
SELECT transfer(11, 13, 250.00, 'order-9f2c', 'Rent');
SELECT * FROM account_statement(11, CURRENT_DATE - 30, CURRENT_DATE);
SELECT * FROM v_reconciliation;   -- should return no rows
```
