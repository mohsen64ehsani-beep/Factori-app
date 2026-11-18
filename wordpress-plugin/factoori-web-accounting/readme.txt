=== Factoori Web Accounting ===
Contributors: factoori
Tags: accounting, invoice, supabase, factoori
Requires at least: 6.2
Tested up to: 6.8
Requires PHP: 7.4
Stable tag: 0.1.0
License: GPLv2 or later

A full-screen, responsive Factoori accounting workspace that uses the same Supabase Auth account and business data as the Factoori Android app.

== Installation ==
1. Upload and activate the plugin ZIP in WordPress.
2. Open Settings > Factoori Web and verify the Supabase URL and Publishable key.
3. The plugin automatically creates a dedicated «حسابداری آنلاین فاکتوری» page at `/factoori-accounting` when activated.
4. Set the professional-version purchase URL in Settings > Factoori Web if needed.

== Shared account ==
Users sign in or register with Supabase Auth. They must use the same email and password as the Android application. Business membership and business records are read from the shared Factoori database.

== Current web features ==
* Shared email/password sign-in and sign-up.
* Business creation and business switching.
* Dashboard summary.
* Contact/customer/supplier creation and list.
* Product creation and list.
* Sales and purchase invoice draft creation.
* Bidirectional customer, supplier and product sync with the Android legacy sync stream.
* Web-created goods-sale drafts are mirrored into the Android invoice stream; Android-origin invoice records are visible in the web invoice list.
* Posting supported goods-sale and purchase drafts through validated database RPCs.
* Responsive full-screen desktop and mobile interface.
* Optional prominent professional-upgrade link.

== Security ==
The plugin uses only the Supabase Publishable key in the browser. Never enter a service_role or secret key. Row Level Security and permission-checked database functions enforce business access. Invoice creation and posting are performed by database RPCs; the plugin does not write journal or stock records directly.

== Notes ==
This is the first web workspace release. Customer, supplier and product records are bridged bidirectionally between the normalized web tables and the Android sync stream. Goods-sale drafts created on the web are mirrored into Android; mobile-origin invoice records are listed on the web but must pass the owner-controlled normalized import/reconciliation workflow before web posting. Other historical data (payments, stock, cheques and service invoices) still requires the supported import/reconciliation path.
