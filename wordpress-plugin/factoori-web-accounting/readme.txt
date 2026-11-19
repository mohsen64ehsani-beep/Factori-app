=== Factoori Web Accounting ===
Contributors: factoori
Tags: accounting, invoice, supabase, factoori
Requires at least: 6.2
Tested up to: 6.8
Requires PHP: 7.4
Stable tag: 0.2.3
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
* Contact/customer/supplier creation, editing and safe archive (historical documents and balances are retained), per-contact financial profile, shared contact-ledger balances, customer receivables and supplier payables.
* Product creation, editing and safe archive (stock movements and invoice history are retained), with unit cost, sale price, live gross-margin preview, product categories and optional initial warehouse quantity posted through the FIFO opening-stock RPC; cost values are served only to members with the sensitive catalog.cost.read permission.
* Multi-line sales and purchase invoice draft creation for goods and services, invoice detail pages with item-level information, editing drafts while preserving their document number and identity, safe draft archiving without physical deletion, and printable invoice / browser PDF output. Print layouts support modern, classic and minimal styles with configurable HTTPS logo, signature and footer.
* Bidirectional customer, supplier, product cost and category sync with the Android legacy sync stream; cost fields remain in the private sync payload and are permission-filtered in web reads.
* Web-created goods-sale drafts are mirrored into the Android invoice stream; Android-origin invoice records are visible in the web invoice list.
* Posting supported goods-sale and purchase drafts through validated database RPCs.
* Shared financial transaction entry for customer receipts, supplier payments, expenses, other income and account-to-account transfers.
* Dedicated expense/other-income register and supplier ledger with approximate purchase/payment balances.
* Cheque register with deposit, settlement, bounce, cancellation, return and audited settlement-reversal actions plus event history.
* Shared due-date register for receivables, payables and cheques, with settle/cancel actions and legacy Android synchronization.
* Fiscal-period creation, overlap prevention, guarded close/reopen and Android legacy synchronization.
* Inventory balances from the complete movement history, FIFO stock transfers, opening stock and wastage posting.
* Validated sales and purchase returns from original posted goods invoices, including stock, FIFO and ledger effects.
* Read-only legacy data preview and guarded import of supported customers, suppliers, products, services, warehouses, fiscal periods, sales/service invoice drafts, purchase drafts, cash receipts, pending cheques, supplier payments, expenses and other income.
* Web-origin financial, account-transfer and inventory operations mirrored to the Android sync collections.
* Shared service catalog management and service-sale invoice drafts with Android `serviceInv` synchronization.
* Web purchase invoice lines are mirrored to Android `purchases`; unit cost remains in the private sync payload partition.
* Six-month sales/purchase report with responsive charts and monthly comparison, including legacy Android sales history where available; dashboard adds six-month sales, purchases, receipts and payments visualization.
* Editable business settings for currency, timezone, Jalali calendar, costing/tax policy and negative-stock rules, with safeguards against changing currency or costing after posted activity.
* Permission-gated team member listing, role changes and suspend/reactivate controls; inviting a new member is not yet available in the web workspace.
* Secure JSON business backup export, including normalized records and public Android sync records; private sync payloads and secret settings are excluded.
* Create financial accounts with automatic chart-of-accounts mapping and create warehouses; both publish compatible master records for Android sync. Existing legacy app accounts can be adopted into normalized web accounts with conflict detection. Opening balances are deliberately not auto-imported.
* Persian (Jalali) calendar display and date entry across invoice, financial, cheque, inventory and report screens; dates are converted to Gregorian ISO before database writes.
* Responsive full-screen desktop and mobile interface with refreshed dashboard, cards, tables, compact five-item mobile navigation with an expandable menu, touch-friendly forms and financial charts.
* Invoice composer includes selectable visual styles and accent colors for print/PDF. The selected print appearance is saved locally in the browser.
* Optional mobile-app download link configured in Settings > Factoori Web and displayed in the workspace navigation.
* Optional prominent professional-upgrade link.

== Security ==
The plugin uses only the Supabase Publishable key in the browser. Never enter a service_role or secret key. Row Level Security and permission-checked database functions enforce business access. Invoice creation and posting are performed by database RPCs; the plugin does not write journal or stock records directly.

== Notes ==
This is the first web workspace release. Customer, supplier and product records are bridged bidirectionally between the normalized web tables and the Android sync stream. Goods-sale drafts created on the web are mirrored into Android; mobile-origin invoice records are listed on the web but must pass the owner-controlled normalized import/reconciliation workflow before web posting. Cleared/returned legacy cheques, account transfers, opening balances and invoice allocations remain visible as deferred legacy records until their mappings and event dates can be reconciled safely; new web financial transactions, cheques and stock movements are mirrored to Android.
