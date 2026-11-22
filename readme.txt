=== Factoori Web Accounting ===
Contributors: factoori
Tags: accounting, invoice, supabase, factoori
Requires at least: 6.2
Tested up to: 6.8
Requires PHP: 7.4
Stable tag: 0.3.2
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
* Contact/customer/supplier creation, per-contact financial profile, shared contact-ledger balances, customer receivables and supplier payables.
* Product creation and list with unit cost, sale price, live gross-margin preview, product categories and optional initial warehouse quantity posted through the FIFO opening-stock RPC; cost values are served only to members with the sensitive catalog.cost.read permission.
* Multi-line sales and purchase invoice draft creation for goods and services, with printable invoice / browser PDF output. Print layouts support modern, classic and minimal styles with configurable HTTPS logo, signature and footer.
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

== 0.3.2 ==
* Unified normalized and legacy cheque records into one searchable, paginated register with at least 10 records per page, deduplication, readable contact names, and per-cheque detail/history modal.
* Added Persian labels for cheque creation and status events; safe edit/delete is enabled only for pending cheques with no financial link and no event beyond initial creation.
* Improved cheque register typography, responsive layout and desktop navigation width.
* Updated dashboard totals and six-month cash-flow chart to use normalized posted transaction directions consistently; today's receipts/payments are shown on the metric cards and recent activity now includes receipts and payments.
* Refresh shared business data when returning to the dashboard and load a larger recent transaction/cheque history.
* Included the required atomic cash/cheque invoice settlement migration in the package under supabase/migrations. Apply this SQL once in Supabase SQL Editor before using cash/cheque invoice settlement; it is not auto-applied by WordPress.

== 0.3.1 ==
* Fixed credit invoice registration to use the existing create_and_post_document RPC when the settlement wrapper migration is not yet installed.
* Added a clear error for cash/cheque invoice settlement when the database settlement migration is missing, instead of a generic missing-RPC failure.

== 0.3.0 ==
* Fixed the invoice creation screen JavaScript error that prevented the invoice section from opening.
* Added customer cheque receipt entry directly to the Receipts & Payments form, with an inline cheque-details panel and pending-cheque handling.
* Made the Cheques section a management register with safe edit/delete controls for pending cheques that have no financial events or linked documents.
* Kept cheque status transitions and the event audit history; legacy cheque records remain read-only.

== 0.2.8 ==
* Rebuilt the dashboard around the approved executive sample: purple and teal palette, metric cards, financial trend chart, shortcuts and recent activity.
* Rebuilt invoice creation as a hybrid three-pane workspace with product rows and a live totals summary.
* Removed raw JSON/HTML payload dumps from legacy sync, finance and inventory details; only readable field summaries are displayed.
* Updated the shared interface palette to purple #6258e8 and teal #18b89a, including navigation, controls, cards and date picker.

== 0.2.9 ==
* Simplified invoice entry to one focused sales-invoice form with customer, date, item, quantity, unit price, totals and payment fields.
* Moved invoice history and sales/purchase returns into their own navigation sections.
* Added business entitlement lookup and app-matched free-tier caps: 3 invoices/day, 2 lines/invoice, 5 customers, 5 products, 50 services and 1 warehouse.
* Added server-side daily invoice quota and per-invoice line enforcement to the pending database migration; service and warehouse insert caps are also guarded there.

== Security ==
The plugin uses only the Supabase Publishable key in the browser. Never enter a service_role or secret key. Row Level Security and permission-checked database functions enforce business access. Invoice creation and posting are performed by database RPCs; the plugin does not write journal or stock records directly.

== Notes ==
This is the first web workspace release. Customer, supplier and product records are bridged bidirectionally between the normalized web tables and the Android sync stream. Goods-sale drafts created on the web are mirrored into Android; mobile-origin invoice records are listed on the web but must pass the owner-controlled normalized import/reconciliation workflow before web posting. Cleared/returned legacy cheques, account transfers, opening balances and invoice allocations remain visible as deferred legacy records until their mappings and event dates can be reconciled safely; new web financial transactions, cheques and stock movements are mirrored to Android.
