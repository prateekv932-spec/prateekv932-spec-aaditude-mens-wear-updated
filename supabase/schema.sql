-- Aaditude Mens Wear: Supabase schema
-- Run this entire file in Supabase Dashboard > SQL Editor.

create extension if not exists pgcrypto;
create sequence if not exists public.aaditude_order_seq start 1001;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'customer' check (role in ('customer','admin')),
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null,
  price numeric(10,2) not null check (price > 0),
  compare_at numeric(10,2),
  image_url text,
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('AAD-' || nextval('public.aaditude_order_seq')::text),
  customer_name text not null,
  phone text not null,
  delivery_address text not null,
  note text,
  total numeric(10,2) not null default 0,
  status text not null default 'Placed' check (status in ('Placed','Confirmed','Packed','Out for delivery','Delivered','Cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price numeric(10,2) not null check (unit_price > 0),
  quantity integer not null check (quantity > 0),
  line_total numeric(10,2) not null check (line_total > 0)
);

create or replace function public.is_aaditude_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin'); $$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Profiles: users can read their own role; only admins can manage profiles.
drop policy if exists "profile self read" on public.profiles;
create policy "profile self read" on public.profiles for select to authenticated using (id = auth.uid() or public.is_aaditude_admin());
drop policy if exists "admin manage profiles" on public.profiles;
create policy "admin manage profiles" on public.profiles for all to authenticated using (public.is_aaditude_admin()) with check (public.is_aaditude_admin());

-- Products: visitors see active products; owner can create/update/archive inventory.
drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products for select to anon, authenticated using (active = true or public.is_aaditude_admin());
drop policy if exists "admin insert products" on public.products;
create policy "admin insert products" on public.products for insert to authenticated with check (public.is_aaditude_admin());
drop policy if exists "admin update products" on public.products;
create policy "admin update products" on public.products for update to authenticated using (public.is_aaditude_admin()) with check (public.is_aaditude_admin());

-- Only the owner can read/update orders and their line items. Customer order creation
-- is handled through the validated RPC below, not direct table insert permissions.
drop policy if exists "admin read orders" on public.orders;
create policy "admin read orders" on public.orders for select to authenticated using (public.is_aaditude_admin());
drop policy if exists "admin update orders" on public.orders;
create policy "admin update orders" on public.orders for update to authenticated using (public.is_aaditude_admin()) with check (public.is_aaditude_admin());
drop policy if exists "admin read order items" on public.order_items;
create policy "admin read order items" on public.order_items for select to authenticated using (public.is_aaditude_admin());

create or replace function public.place_customer_order(
  p_customer_name text,
  p_phone text,
  p_address text,
  p_note text default '',
  p_items jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_order_number text;
  v_total numeric(10,2) := 0;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
begin
  if length(trim(coalesce(p_customer_name,''))) < 2 then raise exception 'Please enter a valid customer name.'; end if;
  if length(regexp_replace(coalesce(p_phone,''),'[^0-9]','','g')) < 10 then raise exception 'Please enter a valid phone number.'; end if;
  if length(trim(coalesce(p_address,''))) < 12 then raise exception 'Please enter a complete delivery address.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Your cart is empty.'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Too many different products in one order.'; end if;

  -- Recalculate prices on the server; never trust totals sent by the browser.
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 20 then raise exception 'Product quantity must be between 1 and 20.'; end if;
    select * into v_product from public.products where id = (v_item->>'product_id')::uuid and active = true;
    if not found then raise exception 'One of the selected products is no longer available.'; end if;
    v_total := v_total + (v_product.price * v_qty);
  end loop;

  insert into public.orders(customer_name,phone,delivery_address,note,total)
  values(trim(p_customer_name),trim(p_phone),trim(p_address),left(coalesce(p_note,''),1000),v_total)
  returning id, order_number into v_order_id, v_order_number;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products where id = (v_item->>'product_id')::uuid and active = true;
    insert into public.order_items(order_id,product_id,product_name,unit_price,quantity,line_total)
    values(v_order_id,v_product.id,v_product.name,v_product.price,v_qty,v_product.price*v_qty);
  end loop;

  return jsonb_build_object('id',v_order_id,'order_number',v_order_number,'total',v_total);
end;
$$;

revoke all on function public.place_customer_order(text,text,text,text,jsonb) from public;
grant execute on function public.place_customer_order(text,text,text,text,jsonb) to anon, authenticated;
grant usage, select on sequence public.aaditude_order_seq to anon, authenticated;

-- Public tracking lookup: requires both the order number and the phone number
-- used at checkout. Does not return the delivery address or customer name.
create or replace function public.track_customer_order(p_order_number text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_items jsonb;
begin
  select * into v_order
  from public.orders
  where upper(order_number) = upper(trim(coalesce(p_order_number,'')))
    and regexp_replace(phone, '[^0-9]', '', 'g') = regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g');
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('product_name', product_name, 'quantity', quantity, 'unit_price', unit_price) order by id), '[]'::jsonb)
    into v_items from public.order_items where order_id = v_order.id;
  return jsonb_build_object('order_number', v_order.order_number, 'status', v_order.status, 'total', v_order.total, 'created_at', v_order.created_at, 'updated_at', v_order.updated_at, 'items', v_items);
end;
$$;
revoke all on function public.track_customer_order(text,text) from public;
grant execute on function public.track_customer_order(text,text) to anon, authenticated;


-- Optional sample catalogue. Replace these with the shop's real inventory/prices.
insert into public.products(name,category,price,compare_at,image_url,description)
select * from (values
 ('The Everyday Oxford','Shirts',1299,1799,'https://images.unsplash.com/photo-1598033129183-c4f50c736f10?auto=format&fit=crop&w=900&q=85','A clean, versatile shirt for everyday dressing.'),
 ('After Hours Tee','T-Shirts',799,999,'https://images.unsplash.com/photo-1521572163474-6864f9cf17ab?auto=format&fit=crop&w=900&q=85','An easy essential with a relaxed silhouette.'),
 ('Modern Tailored Shirt','Formal Wear',1599,1999,'https://images.unsplash.com/photo-1603252109303-2751441dd157?auto=format&fit=crop&w=900&q=85','A refined staple for a sharper finish.'),
 ('Weekend Denim','Jeans & Trousers',1899,2299,'https://images.unsplash.com/photo-1542272604-787c3835535d?auto=format&fit=crop&w=900&q=85','Timeless denim with an easy-to-style character.'),
 ('The Neutral Layer','Casual Wear',1499,1899,'https://images.unsplash.com/photo-1618354691373-d851c5c3a990?auto=format&fit=crop&w=900&q=85','A considered layer with a clean modern profile.'),
 ('City Polo','T-Shirts',999,1299,'https://images.unsplash.com/photo-1627225924765-552d49cf47ad?auto=format&fit=crop&w=900&q=85','A smart-casual staple for your daily rotation.'),
 ('Classic Occasion Set','Ethnic Wear',2499,2999,'https://images.unsplash.com/photo-1617137968427-85924c800a22?auto=format&fit=crop&w=900&q=85','A sample occasion look for celebrations.'),
 ('Straight Fit Essential','Jeans & Trousers',1699,2099,'https://images.unsplash.com/photo-1512436991641-6745cdb1723f?auto=format&fit=crop&w=900&q=85','An adaptable everyday silhouette.')
) as seed(name,category,price,compare_at,image_url,description)
where not exists (select 1 from public.products);
