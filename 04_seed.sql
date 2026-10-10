-- =====================================================================
-- Seed data
-- =====================================================================
SET search_path TO bank;

INSERT INTO currencies VALUES ('UZS', 'Uzbek som', 2), ('USD', 'US dollar', 2), ('EUR', 'Euro', 2);

-- Internal bank accounts (customer_id IS NULL)
INSERT INTO accounts (iban, customer_id, currency) VALUES
  ('VAULT-UZS', NULL, 'UZS'), ('VAULT-USD', NULL, 'USD'), ('VAULT-EUR', NULL, 'EUR'),
  ('FEE-UZS',   NULL, 'UZS'), ('FEE-USD',   NULL, 'USD'), ('FEE-EUR',   NULL, 'EUR');

INSERT INTO customers (full_name, national_id, phone, risk_level)
SELECT 'Customer ' || g, 'AB' || lpad(g::text, 7, '0'), '+99890' || lpad((g * 7919 % 10000000)::text, 7, '0'), 1 + g % 3
FROM generate_series(1, 200) g;

INSERT INTO accounts (iban, customer_id, currency, overdraft_limit, daily_limit)
SELECT 'UZ' || lpad(c.customer_id::text, 4, '0') || cur, c.customer_id, cur,
       CASE WHEN c.risk_level = 1 THEN 500 ELSE 0 END,
       CASE cur WHEN 'UZS' THEN 50000000 ELSE 10000 END
FROM customers c
CROSS JOIN unnest(ARRAY['USD', 'UZS']) cur;

-- Initial deposits through the business function (keeps the ledger consistent)
SELECT count(cash_operation(account_id,
                            CASE currency WHEN 'UZS' THEN 5000000 + (account_id * 37919 % 20000000) ELSE 200 + (account_id * 131 % 5000) END,
                            'deposit'))
FROM accounts WHERE customer_id IS NOT NULL;

-- Random transfers between USD accounts
SELECT count(transfer(a.account_id, b.account_id, 10 + (g % 90), 'seed-' || g, 'Seed transfer'))
FROM generate_series(1, 300) g
JOIN accounts a ON a.iban = 'UZ' || lpad((1 + g % 200)::text, 4, '0')        || 'USD'
JOIN accounts b ON b.iban = 'UZ' || lpad((1 + (g * 7) % 200)::text, 4, '0')  || 'USD'
WHERE a.account_id <> b.account_id;
