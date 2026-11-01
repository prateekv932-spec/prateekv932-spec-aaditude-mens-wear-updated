# Aaditude Mens Wear — Customer Store + Owner Portal

This is a full-stack-ready React + Vite storefront with a separate, protected owner dashboard. It uses Supabase for shared product inventory, guest checkout/order creation, owner authentication, order management and sales reporting.

## Included features

### Customer storefront
- Premium responsive menswear storefront and category/search filters.
- Product cards read live inventory and prices from Supabase.
- Cart with quantity controls and totals.
- Guest checkout with customer name, phone, delivery address and optional note.
- Cash-on-delivery / pay-at-store order request (no online payment gateway is configured).
- Order totals and product prices are recalculated on the database, not trusted from the browser.

### Owner portal
- Separate Host Portal entry in the website navigation.
- Email/password sign-in using Supabase Auth.
- Admin-only dashboard, product create/edit/archive, order list and delivery status updates.
- Overview metrics for total orders, delivered sales, active orders and live products.
- Delivered sales total includes only orders marked Delivered.

## 1. Set up Supabase

1. Create a project at https://supabase.com/.
2. Open **SQL Editor** in the Supabase dashboard.
3. Run the complete `supabase/schema.sql` file.
4. In **Project Settings → API**, copy the Project URL and anon/public key.
5. Copy `.env.example` to a new file named `.env` in the project root.
6. Fill in:

```env
VITE_SUPABASE_URL=https://YOUR-PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_OR_PUBLISHABLE_KEY
```

Never put a Supabase `service_role` key in this frontend project or in Vercel environment variables prefixed with `VITE_`.

## 2. Create the shop owner's login

1. In Supabase, open **Authentication → Users → Add user**.
2. Create the shop owner's email/password account. Confirm the user if Supabase asks.
3. Copy the new user's UUID.
4. In SQL Editor, run this query after replacing the UUID:

```sql
insert into public.profiles (id, role)
values ('PASTE-AUTH-USER-UUID-HERE', 'admin')
on conflict (id) do update set role = 'admin';
```

Only accounts with `profiles.role = 'admin'` can enter the owner dashboard. Do not create a public admin sign-up form.

## 3. Run locally

```bash
npm install
npm run dev
```

Open the local URL printed by Vite. Use **Host portal** in the top navigation to sign in as the owner.

## 4. Deploy to Vercel

- Push the complete project folder to GitHub.
- Import the repository in Vercel.
- Framework preset: **Vite**
- Build command: `npm run build`
- Output directory: `dist`
- Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in Vercel → Project → Settings → Environment Variables.
- Redeploy after adding the environment variables.
- In Supabase Authentication URL settings, add your deployed Vercel URL to the allowed site URLs.

## Important operating notes

- The eight initial catalogue entries and prices inserted by `schema.sql` are illustrative placeholders. Replace them with the shop's actual stock and prices in the owner portal before taking customer orders.
- Product photos are image URLs. Use image URLs the shop has permission to use.
- Checkout currently records a customer order request with **Cash on Delivery / pay at store**. It does not collect online payments. Add a payment provider and server-side payment verification separately before enabling prepaid checkout.
- The customer receives an on-screen order number after placing an order. The owner sees the order in the Host Portal and can update its status. This starter does not yet send automatic SMS/WhatsApp/email delivery notifications to customers.
- Guest checkout stores customer contact and delivery details in the Supabase database. Restrict dashboard access to the owner and protect the Supabase project account.
- The schema uses row-level security. Customer order creation is handled by a database function that calculates current product prices on the server. Only the admin role can read/manage orders and inventory.
- For a production store, add inventory/stock quantities, order cancellation/refund rules, customer notifications, backups and a payment gateway as required.

## Order tracking update

This version adds an order-success panel, a shareable tracking URL, and a tracking lookup that asks for the order number and checkout phone number. The tracking lookup uses the `public.track_customer_order(text,text)` RPC included in `supabase/schema.sql`.

After deploying this updated source, open Supabase SQL Editor and run the updated `supabase/schema.sql` so the tracking RPC exists in your project. It is designed to be re-runnable. Keep RLS enabled and do not expose the service-role key.

**Automatic notifications:** this source does not send SMS or automatically message the customer's own WhatsApp. The success panel can open WhatsApp with a prepared order message to the store, which the customer must send. Automatic outbound WhatsApp messages require WhatsApp Business Platform/API setup; SMS requires an SMS provider and server-side credentials. Never put provider secrets in frontend `VITE_` variables.
