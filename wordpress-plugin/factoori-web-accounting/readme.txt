=== Factoori Web Accounting ===
Contributors: factoori
Tags: accounting, invoice, supabase, factoori
Requires at least: 6.2
Tested up to: 6.8
Requires PHP: 7.4
Stable tag: 0.1.3
License: GPLv2 or later

A full-screen, responsive Factoori accounting workspace that uses the same Supabase Auth account and business data as the Factoori Android app.

== Installation ==
1. Upload and activate the plugin ZIP in WordPress.
2. Open Settings > Factoori Web and verify the Supabase URL and Publishable key.
3. The plugin automatically creates a dedicated «حسابداری آنلاین فاکتوری» page at `/factoori-accounting` when activated.
4. Open Settings > Factoori Web and use the direct link to the automatically created accounting page.
5. Set the professional-version purchase URL in Settings > Factoori Web if needed.

== Shared account ==
Users sign in or register with Supabase Auth. They must use the same email and password as the Android application. Business membership and business records are read from the shared Factoori database.

== Current web features ==
* Shared email/password sign-in and sign-up.
* Business creation and business switching.
* Management dashboard with sales, purchases, receipts, payments, pending cheques, low-stock indicators, estimated financial-account balances and current stock quantities.
* Contact/customer/supplier creation, per-contact financial profile and recent document/transaction history.
* Product creation and list with unit cost, sale price, live gross-margin preview and product categories; cost values are served only to members with the sensitive catalog.cost.read permission.
* Sales and purchase invoice draft creation.
* Bidirectional customer, supplier, product cost and category sync with the Android legacy sync stream; cost fields remain in the private sync payload and are permission-filtered in web reads.
* Web-created goods-sale drafts are mirrored into the Android invoice stream; Android-origin invoice records are visible in the web invoice list.
* Posting supported goods-sale and purchase drafts through validated database RPCs.
* Shared financial transaction entry for customer receipts, supplier payments, expenses, other income and account-to-account transfers.
* Dedicated expense/other-income register and supplier ledger with approximate purchase/payment balances.
* Cheque register with normalized lifecycle transitions and accounting settlement.
* Inventory balances from the complete movement history, FIFO stock transfers, opening stock and wastage posting.
* Read-only legacy data preview and guarded import of supported customers, suppliers, products, services, warehouses, fiscal periods, sales/service invoice drafts, purchase drafts, cash receipts, pending cheques, supplier payments, expenses and other income.
* Web-origin financial, account-transfer and inventory operations mirrored to the Android sync collections.
* Shared service catalog management and service-sale invoice drafts with Android `serviceInv` synchronization.
* Web purchase invoice lines are mirrored to Android `purchases`; unit cost remains in the private sync payload partition.
* Six-month sales/purchase report with responsive charts and monthly comparison (based on the currently loaded posted documents).
* Business settings overview with currency, timezone, costing/tax settings and fiscal-period status.
* Responsive full-screen desktop and mobile interface with refreshed dashboard, cards, tables and navigation.
* Optional prominent professional-upgrade link.

== Security ==
The plugin uses only the Supabase Publishable key in the browser. Never enter a service_role or secret key. Row Level Security and permission-checked database functions enforce business access. Invoice creation and posting are performed by database RPCs; the plugin does not write journal or stock records directly.

== Notes ==
This is the first web workspace release. Customer, supplier and product records are bridged bidirectionally between the normalized web tables and the Android sync stream. Goods-sale drafts created on the web are mirrored into Android; mobile-origin invoice records are listed on the web but must pass the owner-controlled normalized import/reconciliation workflow before web posting. Cleared/returned legacy cheques, account transfers, opening balances and invoice allocations remain visible as deferred legacy records until their mappings and event dates can be reconciled safely; new web financial transactions, cheques and stock movements are mirrored to Android.
