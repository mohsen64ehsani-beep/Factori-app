(() => {
  'use strict';
  const cfg = window.FACTOORI_WEB_CONFIG || {};
  const root = document.getElementById('factoori-web-root');
  if (!root) return;
  const base = String(cfg.supabaseUrl || '').replace(/\/$/, '');
  const key = String(cfg.publishableKey || '');
  const storageKey = 'factoori_web_session_v1';
  const state = {session:null,user:null,businesses:[],business:null,contacts:[],products:[],services:[],documents:[],legacyDocuments:[],warehouses:[],accounts:[],transactions:[],cheques:[],stockMovements:[],inventoryBalances:[],legacyCollections:{},legacyPreview:null,legacyReconciliation:null,legacyImportResult:null,section:'dashboard',signup:false,busy:false};
  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const money = v => new Intl.NumberFormat('fa-IR').format(Number(v || 0));
  const dateFa = v => { try { return new Intl.DateTimeFormat('fa-IR').format(new Date(v+'T12:00:00')); } catch (_) { return v || '—'; } };
  const today = () => new Date().toISOString().slice(0,10);
  const idempotency = () => 'web-' + (crypto.randomUUID ? crypto.randomUUID() : Date.now()+'-'+Math.random().toString(16).slice(2));
  const getStored = () => { try { return JSON.parse(sessionStorage.getItem(storageKey) || 'null'); } catch (_) { return null; } };
  const saveSession = s => { state.session=s; if(s) sessionStorage.setItem(storageKey,JSON.stringify(s)); else sessionStorage.removeItem(storageKey); };
  const toast = message => { let el=document.querySelector('.fw-toast'); if(!el){el=document.createElement('div');el.className='fw-toast';document.body.appendChild(el);} el.textContent=message; el.hidden=false; clearTimeout(el._t); el._t=setTimeout(()=>el.remove(),3600); };
  async function request(path, options={}, retry=true) {
    if (!base || !key) throw new Error('تنظیمات اتصال به پایگاه داده کامل نیست.');
    const headers = Object.assign({'apikey':key,'Authorization':'Bearer '+(state.session?.access_token || key)}, options.headers || {});
    if (options.body && !headers['Content-Type']) headers['Content-Type']='application/json';
    const response = await fetch(base+path,Object.assign({},options,{headers}));
    if(response.status===401 && retry && state.session?.refresh_token){
      const refreshed=await fetch(base+'/auth/v1/token?grant_type=refresh_token',{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:state.session.refresh_token})});
      if(refreshed.ok){const s=await refreshed.json();saveSession(s);return request(path,options,false);}
    }
    const raw=await response.text(); let data=null; try{data=raw?JSON.parse(raw):null;}catch(_){data=raw;}
    if(!response.ok){const msg=data?.msg||data?.message||data?.error_description||data?.error||('HTTP '+response.status);throw new Error(typeof msg==='string'?msg:JSON.stringify(msg));}
    return data;
  }
  const rest = (table, query='') => request('/rest/v1/'+table+(query?'?'+query:''),{method:'GET'});
  const rpc = (name, body) => request('/rest/v1/rpc/'+name,{method:'POST',body:JSON.stringify(body)});
  async function auth(mode,email,password,name=''){
    const path=mode==='signup'?'/auth/v1/signup':'/auth/v1/token?grant_type=password';
    const body=mode==='signup'?{email,password,data:{display_name:name}}:{email,password};
    const response=await fetch(base+path,{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify(body)});
    const data=await response.json().catch(()=>({}));
    if(!response.ok) throw new Error(data.msg||data.message||data.error_description||'ورود یا ثبت‌نام انجام نشد.');
    if(data.access_token) saveSession(data); else if(mode==='signup') toast('حساب ساخته شد. ایمیل خود را برای تأیید بررسی کنید، سپس وارد شوید.');
    return data;
  }
  async function restore(){
    const saved=getStored();
    if(!saved?.access_token){render();return;}
    saveSession(saved);
    try{state.user=await request('/auth/v1/user');await loadBusinesses();}
    catch(_){saveSession(null);state.user=null;}
    render();
  }
  async function loadBusinesses(){
    const rows=await rest('business_members','select=business_id,role_code,status,businesses(id,name,status)&user_id=eq.'+encodeURIComponent(state.user.id)+'&status=eq.active&order=created_at.asc');
    state.businesses=(rows||[]).map(x=>x.businesses).filter(Boolean);
    const selected=state.businesses.find(x=>x.id===state.business?.id)||state.businesses[0]||null;
    state.business=selected;
    if(selected) await loadData(); else clearData();
  }
  function clearData(){state.contacts=[];state.products=[];state.services=[];state.documents=[];state.legacyDocuments=[];state.warehouses=[];state.accounts=[];state.transactions=[];state.cheques=[];state.stockMovements=[];state.inventoryBalances=[];state.legacyCollections={};state.legacyPreview=null;state.legacyReconciliation=null;state.legacyImportResult=null;}
  async function loadData(){
    const b=state.business?.id;if(!b){clearData();return;}
    const f='business_id=eq.'+encodeURIComponent(b);
    const results=await Promise.all([
      rest('contacts','select=id,name,contact_type,phone,code,is_active&'+f+'&is_active=eq.true&order=name.asc&limit=200'),
      rest('products','select=id,name,sku,unit_name,sale_price,track_inventory,is_active&'+f+'&is_active=eq.true&order=name.asc&limit=200'),
      rest('documents','select=id,document_type,document_number,document_date,total_amount,status,contact_id,created_at&'+f+'&order=created_at.desc&limit=50'),
      rest('warehouses','select=id,name,is_default,is_active&'+f+'&is_active=eq.true&order=is_default.desc,name.asc'),
      rest('financial_accounts','select=id,name,account_type,is_default,is_active&'+f+'&is_active=eq.true&order=is_default.desc,name.asc'),
      rpc('web_list_legacy_invoices',{p_business_id:b})
    ]);
    [state.contacts,state.products,state.documents,state.warehouses,state.accounts]=results.slice(0,5).map(x=>x||[]);
    const normalizedIds=new Set(state.documents.map(d=>d.id));
    state.legacyDocuments=(results[5]||[]).map(row=>{const p=row.payload||{};const items=Array.isArray(p.items)?p.items:[];const subtotal=items.reduce((sum,x)=>sum+Number(x.q||0)*Number(x.p||0),0);const discount=Number(p.ds||0);const tax=(subtotal-discount)*Number(p.tx||0)/100;return {id:row.legacy_id,document_type:'goods_sale',document_number:p.no,document_date:p.dt,total_amount:Math.max(0,subtotal-discount+tax),status:p.status||'legacy',legacy_source:true,created_at:row.updated_at};}).filter(d=>!normalizedIds.has(d.id));
    const optional=await Promise.allSettled([
      rest('financial_transactions','select=id,transaction_type,direction,amount,transaction_date,reference_number,description,status,account_id,contact_id,financial_accounts(name),contacts(name)&'+f+'&order=transaction_date.desc&limit=100'),
      rest('cheques','select=id,cheque_direction,cheque_number,sayad_id,bank_name,amount,issue_date,due_date,status,contact_id,contacts(name),note&'+f+'&order=due_date.asc&limit=100'),
      rest('stock_movements','select=id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,note,products(name),warehouses(name)&'+f+'&order=movement_date.desc&limit=150'),
      rpc('web_list_inventory_balances',{p_business_id:b}),
      rest('services','select=id,name,description,sale_price,is_active&'+f+'&is_active=eq.true&order=name.asc')
    ]);
    state.transactions=optional[0].status==='fulfilled'?(optional[0].value||[]):[];
    state.cheques=optional[1].status==='fulfilled'?(optional[1].value||[]):[];
    state.stockMovements=optional[2].status==='fulfilled'?(optional[2].value||[]):[];
    state.inventoryBalances=optional[3].status==='fulfilled'?(optional[3].value||[]):[];
    state.services=optional[4].status==='fulfilled'?(optional[4].value||[]):[];
    const legacyGroups=[
      ['pay','debt','creditors','creditorPayments','expenses','otherincome','supplierPayments','moneytransfers'],
      ['serviceInv','purchases','returns','duedates','fiscal'],
      ['stockMoves','warehouseStocks','wastage','transfers','opening','warehouses'],
      ['services','categories','smsHistory']
    ];
    const legacyResults=await Promise.all(legacyGroups.map(cols=>rpc('web_list_legacy_collections',{p_business_id:b,p_collections:cols}).catch(()=>({}))));
    state.legacyCollections=Object.assign({},...legacyResults);
  }
  function authView(){
    root.innerHTML='<div class="fw-auth-wrap"><section class="fw-auth-card"><div class="fw-brand"><div class="fw-brand-mark">ف</div><div><b>فاکتوری</b><small>سیستم یکپارچه حسابداری</small></div></div><h1>'+(state.signup?'ساخت حساب کاربری':'خوش آمدید')+'</h1><p class="fw-sub">با همان حساب اپلیکیشن اندروید وارد شوید؛ اطلاعات در هر دو نسخه مشترک است.</p><form data-form="auth">'+(state.signup?'<div class="fw-field"><label>نام و نام خانوادگی</label><input name="name" autocomplete="name" required placeholder="نام شما"></div>':'')+'<div class="fw-field"><label>ایمیل</label><input name="email" type="email" autocomplete="email" required placeholder="name@example.com" dir="ltr"></div><div class="fw-field"><label>رمز عبور</label><input name="password" type="password" autocomplete="'+(state.signup?'new-password':'current-password')+'" minlength="8" required placeholder="حداقل ۸ کاراکتر" dir="ltr"></div><button class="fw-btn fw-full" type="submit">'+(state.signup?'ایجاد حساب':'ورود به حساب')+'</button></form><div class="fw-auth-toggle">'+(state.signup?'قبلاً حساب دارید؟':'حساب ندارید؟')+' <button class="fw-link" data-action="toggle-auth">'+(state.signup?'ورود':'ثبت‌نام')+'</button></div><div class="fw-auth-toggle">اطلاعات ورود اپلیکیشن و نسخه وب یکسان است.</div></section></div>';
  }
  function shell(content,title,subtitle='مدیریت یکپارچه کسب‌وکار شما'){
    const nav=[['dashboard','▦','داشبورد'],['invoices','▤','فاکتورها'],['contacts','♙','اشخاص'],['products','◇','کالاها'],['finance','ت','دریافت و پرداخت'],['cheques','▣','چک‌ها'],['inventory','▧','انبار و موجودی'],['legacy','⇄','همگام‌سازی و ورود داده']];
    root.innerHTML='<div class="fw-layout"><aside class="fw-sidebar"><div class="fw-brand"><div class="fw-brand-mark">ف</div><div><b>فاکتوری</b><small>حسابداری آنلاین</small></div></div><div class="fw-business"><small>کسب‌وکار فعال</small><select id="fw-business">'+state.businesses.map(b=>'<option value="'+esc(b.id)+'" '+(b.id===state.business?.id?'selected':'')+'>'+esc(b.name)+'</option>').join('')+'</select></div><nav class="fw-nav">'+nav.map(n=>'<button data-section="'+n[0]+'" class="'+(state.section===n[0]?'active':'')+'"><i>'+n[1]+'</i>'+n[2]+'</button>').join('')+'</nav><div class="fw-side-bottom">'+(cfg.purchaseUrl?'<a class="fw-purchase" href="'+esc(cfg.purchaseUrl)+'" target="_blank" rel="noopener">★ ارتقا به نسخه حرفه‌ای</a>':'')+'<div class="fw-user">'+esc(state.user?.email||'')+'</div><button class="fw-btn ghost fw-full" data-action="logout">خروج از حساب</button></div></aside><main class="fw-main"><div class="fw-content"><header class="fw-topbar"><div><h1>'+title+'</h1><p>'+subtitle+'</p></div><div class="fw-top-actions">'+(cfg.purchaseUrl?'<a class="fw-purchase" href="'+esc(cfg.purchaseUrl)+'" target="_blank" rel="noopener">★ نسخه حرفه‌ای</a>':'')+'<button class="fw-btn ghost" data-action="refresh">↻ بروزرسانی</button></div></header>'+content+'</div></main></div>';
  }
  function table(rows,heads,empty){
    if(!rows.length)return '<div class="fw-empty">'+empty+'</div>';
    return '<div class="fw-table-wrap"><table class="fw-table"><thead><tr>'+heads.map(h=>'<th>'+h+'</th>').join('')+'</tr></thead><tbody>'+rows.join('')+'</tbody></table></div>';
  }
  function dashboard(){
    const sales=state.documents.filter(d=>(d.document_type==='goods_sale'||d.document_type==='service_sale')&&d.status==='posted');
    const drafts=state.documents.filter(d=>d.status==='draft').length;
    const total=sales.reduce((a,d)=>a+Number(d.total_amount||0),0);
    const latest=[...state.documents,...state.legacyDocuments].sort((a,b)=>String(b.created_at||b.document_date).localeCompare(String(a.created_at||a.document_date))).slice(0,6).map(d=>'<tr><td>'+esc(d.document_number||'پیش‌نویس')+'</td><td>'+dateFa(d.document_date)+'</td><td>'+money(d.total_amount)+'</td><td><span class="fw-badge '+(d.legacy_source||d.status==='posted'?'green':'gray')+'">'+(d.legacy_source?'همگام از اپ':d.status==='posted'?'ثبت نهایی':'پیش‌نویس')+'</span></td></tr>');
    shell('<div class="fw-grid"><section class="fw-card fw-stat"><div><small>اشخاص ثبت‌شده</small><strong>'+money(state.contacts.length)+'</strong></div><span class="fw-stat-icon">♙</span></section><section class="fw-card fw-stat"><div><small>کالاها و خدمات</small><strong>'+money(state.products.length)+'</strong></div><span class="fw-stat-icon">◇</span></section><section class="fw-card fw-stat"><div><small>فاکتورهای فروش</small><strong>'+money(sales.length)+'</strong></div><span class="fw-stat-icon">▤</span></section><section class="fw-card fw-stat"><div><small>جمع فروش ثبت‌شده</small><strong>'+money(total)+'</strong></div><span class="fw-stat-icon">ت</span></section></div><section class="fw-card"><div class="fw-section-head"><div><h2>آخرین فاکتورها</h2><p>'+money(drafts)+' پیش‌نویس در انتظار ثبت نهایی</p></div><button class="fw-btn secondary" data-section="invoices">مشاهده همه</button></div>'+table(latest,['شماره','تاریخ','مبلغ (ریال)','وضعیت'],'هنوز فاکتوری ثبت نشده است.')+'</section>','داشبورد','نمای کلی عملکرد کسب‌وکار '+esc(state.business?.name||'')); 
  }
  function contacts(){
    const rows=state.contacts.map(c=>'<tr><td>'+esc(c.name)+'</td><td>'+({customer:'مشتری',supplier:'تأمین‌کننده',both:'مشتری و تأمین‌کننده'}[c.contact_type]||'—')+'</td><td>'+esc(c.phone||'—')+'</td><td>'+esc(c.code||'—')+'</td></tr>');
    shell('<div class="fw-two"><section class="fw-card"><div class="fw-section-head"><div><h2>افزودن شخص جدید</h2><p>ثبت مشتری یا تأمین‌کننده</p></div></div><form data-form="contact"><div class="fw-field"><label>نام شخص / شرکت</label><input name="name" required maxlength="160"></div><div class="fw-field"><label>نوع شخص</label><select name="contact_type"><option value="customer">مشتری</option><option value="supplier">تأمین‌کننده</option><option value="both">هر دو</option></select></div><div class="fw-field"><label>شماره تماس</label><input name="phone" inputmode="tel"></div><div class="fw-field"><label>کد / شناسه</label><input name="code"></div><div class="fw-field"><label>نشانی</label><input name="address"></div><button class="fw-btn fw-full" type="submit">ذخیره شخص</button></form></section><section class="fw-card"><div class="fw-section-head"><div><h2>دفتر اشخاص</h2><p>'+money(state.contacts.length)+' شخص فعال</p></div></div>'+table(rows,['نام','نوع','تلفن','کد'],'هنوز شخصی ثبت نشده است.')+'</section></div>','دفتر اشخاص','مشتریان و تأمین‌کنندگان مشترک میان اپلیکیشن و وب'); 
  }
  function products(){
    const rows=state.products.map(p=>'<tr><td>'+esc(p.name)+'</td><td>'+esc(p.sku||'—')+'</td><td>'+esc(p.unit_name||'عدد')+'</td><td>'+money(p.sale_price)+'</td><td>'+(p.track_inventory?'فعال':'غیرفعال')+'</td></tr>');
    const serviceRows=state.services.map(x=>'<tr><td>'+esc(x.name)+'</td><td>'+esc(x.description||'—')+'</td><td>'+money(x.sale_price)+'</td></tr>');
    shell('<div class="fw-two"><section class="fw-card"><div class="fw-section-head"><div><h2>افزودن کالا</h2><p>کالای جدید در حساب مشترک</p></div></div><form data-form="product"><div class="fw-field"><label>نام کالا</label><input name="name" required maxlength="160"></div><div class="fw-field"><label>کد کالا</label><input name="sku"></div><div class="fw-field"><label>واحد</label><input name="unit_name" value="عدد"></div><div class="fw-field"><label>قیمت فروش (ریال)</label><input name="sale_price" type="number" min="0" step="1" value="0" required></div><div class="fw-field"><label><input type="checkbox" name="track_inventory" checked style="width:auto;min-height:auto"> کنترل موجودی</label></div><button class="fw-btn fw-full" type="submit">ذخیره کالا</button></form></section><section class="fw-card"><div class="fw-section-head"><div><h2>افزودن خدمت</h2><p>خدمات در اپ و نسخه وب مشترک می‌شوند</p></div></div><form data-form="service"><div class="fw-field"><label>نام خدمت</label><input name="name" required maxlength="160"></div><div class="fw-field"><label>توضیحات</label><input name="description" maxlength="1000"></div><div class="fw-field"><label>قیمت فروش (ریال)</label><input name="sale_price" type="number" min="0" step="1" value="0" required></div><button class="fw-btn fw-full" type="submit">ذخیره خدمت</button></form></section></div><div class="fw-two" style="margin-top:16px"><section class="fw-card"><div class="fw-section-head"><div><h2>فهرست کالاها</h2><p>'+money(state.products.length)+' کالای فعال</p></div></div>'+table(rows,['نام کالا','کد','واحد','قیمت فروش (ریال)','موجودی'],'هنوز کالایی ثبت نشده است.')+'</section><section class="fw-card"><div class="fw-section-head"><div><h2>فهرست خدمات</h2><p>'+money(state.services.length)+' خدمت فعال</p></div></div>'+table(serviceRows,['نام خدمت','توضیحات','قیمت فروش (ریال)'],'خدمتی ثبت نشده است.')+'</section></div>','کالاها و خدمات','مدیریت فهرست کالاها و خدمات کسب‌وکار'); 
  }
  function invoices(){
    const rows=[...state.documents,...state.legacyDocuments].sort((a,b)=>String(b.created_at||b.document_date).localeCompare(String(a.created_at||a.document_date))).map(d=>'<tr><td>'+esc(d.document_number||'—')+'</td><td>'+({goods_sale:'فروش کالا',service_sale:'فروش خدمات',purchase:'خرید کالا',service_purchase:'خرید خدمات'}[d.document_type]||esc(d.document_type))+'</td><td>'+dateFa(d.document_date)+'</td><td>'+money(d.total_amount)+'</td><td><span class="fw-badge '+(d.legacy_source||d.status==='posted'?'green':'gray')+'">'+(d.legacy_source?'همگام از اپ':d.status==='posted'?'ثبت نهایی':'پیش‌نویس')+'</span></td><td>'+(d.legacy_source?'از اپلیکیشن':d.status==='draft'?'<button class="fw-link" data-action="post-invoice" data-id="'+esc(d.id)+'">ثبت نهایی</button>':'—')+'</td></tr>');
    const legacyHistory=['serviceInv','purchases','returns'].flatMap(k=>(state.legacyCollections[k]||[]).map(r=>({collection:k,...r}))).sort((a,b)=>String(b.updated_at).localeCompare(String(a.updated_at))).slice(0,40);
    const legacyHistoryRows=legacyHistory.map(r=>'<tr><td>'+esc(({serviceInv:'فاکتور خدمات اپ',purchases:'خریدهای اپ',returns:'مرجوعی‌های اپ'}[r.collection]||r.collection))+'</td><td>'+esc(r.legacy_id)+'</td><td>'+dateFa(r.payload?.dt||r.updated_at?.slice(0,10))+'</td><td>'+money(r.payload?.total||r.payload?.amount||r.payload?.amt||0)+'</td><td><details><summary>جزئیات</summary><pre>'+esc(JSON.stringify(r.payload||{},null,2))+'</pre></details></td></tr>');
    const customers=state.contacts;
    const products=state.products;
    const form='<section class="fw-card"><div class="fw-section-head"><div><h2>صدور پیش‌نویس فاکتور فروش</h2><p>فاکتور در پایگاه داده مشترک ذخیره می‌شود</p></div></div><form data-form="invoice"><div class="fw-form-grid"><div class="fw-field"><label>نوع سند</label><select name="document_type"><option value="goods_sale">فاکتور فروش کالا</option><option value="service_sale">فاکتور فروش خدمات</option><option value="purchase">فاکتور خرید کالا</option></select></div><div class="fw-field"><label>مشتری / تأمین‌کننده</label><select name="contact_id" required><option value="">انتخاب شخص</option>'+customers.map(c=>'<option value="'+esc(c.id)+'">'+esc(c.name)+' · '+({customer:"مشتری",supplier:"تأمین‌کننده",both:"هر دو"}[c.contact_type]||"") +'</option>').join('')+'</select></div><div class="fw-field"><label>انبار</label><select name="warehouse_id"><option value="">بدون انتخاب انبار</option>'+state.warehouses.map(w=>'<option value="'+esc(w.id)+'">'+esc(w.name)+'</option>').join('')+'</select></div><div class="fw-field"><label>کالا</label><select name="product_id"><option value="">انتخاب کالا</option>'+products.map(p=>'<option value="'+esc(p.id)+'" data-price="'+esc(p.sale_price)+'" data-unit="'+esc(p.unit_name)+'">'+esc(p.name)+'</option>').join('')+'</select></div><div class="fw-field"><label>خدمت (برای فاکتور خدمات)</label><select name="service_id"><option value="">انتخاب خدمت</option>'+state.services.map(x=>'<option value="'+esc(x.id)+'" data-price="'+esc(x.sale_price)+'">'+esc(x.name)+'</option>').join('')+'</select></div><div class="fw-field"><label>تعداد</label><input name="quantity" type="number" min="0.0001" step="0.0001" value="1" required></div><div class="fw-field"><label>قیمت واحد (ریال)</label><input name="unit_price" type="number" min="0" step="1" required></div><div class="fw-field"><label>تاریخ فاکتور</label><input name="document_date" type="date" value="'+today()+'" required></div><div class="fw-field wide"><label>توضیحات</label><input name="notes" maxlength="500"></div></div><button class="fw-btn" type="submit">ایجاد پیش‌نویس فاکتور</button></form></section>';
    shell(form+'<section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>فاکتورهای کسب‌وکار</h2><p>'+money(state.documents.length+state.legacyDocuments.length)+' سند اخیر</p></div></div>'+table(rows,['شماره','نوع','تاریخ','مبلغ (ریال)','وضعیت','عملیات'],'فاکتوری ثبت نشده است.')+'</section><section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>سوابق فاکتور و مرجوعی قدیمی اپ</h2><p>این سوابق تا زمان تطبیق و ورود رسمی، فقط‌خواندنی هستند.</p></div></div>'+table(legacyHistoryRows,['نوع سابقه','شناسه','تاریخ','مبلغ','اطلاعات'],'سابقه قدیمی دیگری برای نمایش وجود ندارد.')+'</section>','فاکتورها','صدور و پیگیری اسناد فروش و خرید'); 
  }

  function finance(){
    const rows=state.transactions.map(t=>'<tr><td>'+dateFa(t.transaction_date)+'</td><td>'+esc(({customer_receipt:'دریافت از مشتری',supplier_payment:'پرداخت به تأمین‌کننده',expense_payment:'پرداخت هزینه',other_income:'درآمد متفرقه',customer_refund:'استرداد به مشتری'}[t.transaction_type]||t.transaction_type))+'</td><td>'+esc(t.contacts?.name||'—')+'</td><td>'+esc(t.financial_accounts?.name||'—')+'</td><td>'+money(t.amount)+'</td><td><span class="fw-badge green">ثبت‌شده</span></td></tr>');
    const customerOptions=state.contacts.filter(x=>['customer','both'].includes(x.contact_type)).map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('');
    const supplierOptions=state.contacts.filter(x=>['supplier','both'].includes(x.contact_type)).map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('');
    const accountOptions=state.accounts.map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('');
    const legacyNames=['pay','creditorPayments','supplierPayments','expenses','otherincome','moneytransfers'];
    const legacy=legacyNames.flatMap(k=>(state.legacyCollections[k]||[]).map(r=>({collection:k,...r}))).sort((a,b)=>String(b.updated_at).localeCompare(String(a.updated_at))).slice(0,30);
    const legacyRows=legacy.map(r=>'<tr><td>'+esc(({pay:'دریافت‌های اپ',creditorPayments:'پرداخت بستانکاران',supplierPayments:'پرداخت تأمین‌کننده',expenses:'هزینه‌های اپ',otherincome:'درآمد متفرقه',moneytransfers:'انتقال وجه'}[r.collection]||r.collection))+'</td><td>'+esc(r.legacy_id)+'</td><td>'+dateFa(r.payload?.dt||r.updated_at?.slice(0,10))+'</td><td>'+money(r.payload?.amt||r.payload?.amount||r.payload?.price||0)+'</td><td><details><summary>جزئیات</summary><pre>'+esc(JSON.stringify(r.payload||{},null,2))+'</pre></details></td></tr>');
    const form='<section class="fw-card"><div class="fw-section-head"><div><h2>ثبت دریافت یا پرداخت</h2><p>ثبت مستقیم در دفتر مالی و حسابداری مشترک</p></div></div><form data-form="finance"><div class="fw-form-grid"><div class="fw-field"><label>نوع عملیات</label><select name="transaction_type"><option value="customer_receipt">دریافت از مشتری</option><option value="supplier_payment">پرداخت به تأمین‌کننده</option><option value="expense_payment">پرداخت هزینه</option><option value="other_income">درآمد متفرقه</option></select></div><div class="fw-field"><label>شخص مرتبط</label><select name="contact_id"><option value="">بدون شخص</option>'+customerOptions+supplierOptions+'</select></div><div class="fw-field"><label>صندوق / حساب بانکی</label><select name="account_id" required><option value="">انتخاب حساب</option>'+accountOptions+'</select></div><div class="fw-field"><label>مبلغ (ریال)</label><input name="amount" type="number" min="1" step="1" required></div><div class="fw-field"><label>تاریخ</label><input name="transaction_date" type="date" value="'+today()+'" required></div><div class="fw-field"><label>شماره پیگیری</label><input name="reference_number" maxlength="120"></div><div class="fw-field wide"><label>شرح</label><input name="description" maxlength="500"></div></div><button class="fw-btn" type="submit">ثبت عملیات مالی</button></form></section>';
    shell(form+'<section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>گردش مالی ثبت‌شده</h2><p>'+money(state.transactions.length)+' تراکنش</p></div></div>'+table(rows,['تاریخ','نوع','شخص','حساب','مبلغ (ریال)','وضعیت'],'تراکنش مالی ثبت‌شده‌ای وجود ندارد.')+'</section><section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>سوابق مالی همگام‌شده از اپ</h2><p>سوابق قدیمی اپ بدون تغییر در دفتر اصلی نمایش داده می‌شوند</p></div></div>'+table(legacyRows,['مجموعه','شناسه','تاریخ','مبلغ تقریبی','داده خام'],'رکورد قدیمی برای نمایش موجود نیست.')+'</section>','دریافت و پرداخت','ثبت تراکنش و مشاهده سوابق مالی دو نسخه');
  }
  function cheques(){
    const rows=state.cheques.map(q=>'<tr><td>'+esc(q.cheque_number)+'</td><td>'+esc(q.cheque_direction==='received'?'دریافتی':'پرداختی')+'</td><td>'+esc(q.contacts?.name||'—')+'</td><td>'+dateFa(q.due_date)+'</td><td>'+money(q.amount)+'</td><td>'+esc(({pending:'در انتظار',deposited:'واگذار شده',cleared:'وصول شده',bounced:'برگشتی',cancelled:'لغو شده',returned:'عودت شده'}[q.status]||q.status))+'</td><td>'+(q.status==='pending'||q.status==='deposited'?'<button class="fw-link" data-action="cheque-status" data-id="'+esc(q.id)+'" data-status="'+(q.cheque_direction==='received'&&q.status==='pending'?'deposited':'cleared')+'">'+(q.cheque_direction==='received'&&q.status==='pending'?'واگذاری':'تسویه')+'</button>':'—')+'</td></tr>');
    const people=state.contacts.map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('');
    const accounts=state.accounts.map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('');
    const form='<section class="fw-card"><div class="fw-section-head"><div><h2>ثبت چک جدید</h2><p>ثبت چک دریافتی یا پرداختی با گردش وضعیت</p></div></div><form data-form="cheque"><div class="fw-form-grid"><div class="fw-field"><label>نوع چک</label><select name="cheque_direction"><option value="received">چک دریافتی</option><option value="issued">چک پرداختی</option></select></div><div class="fw-field"><label>شخص</label><select name="contact_id" required><option value="">انتخاب شخص</option>'+people+'</select></div><div class="fw-field"><label>شماره چک</label><input name="cheque_number" required maxlength="80"></div><div class="fw-field"><label>شناسه صیادی</label><input name="sayad_id" inputmode="numeric" maxlength="16"></div><div class="fw-field"><label>بانک</label><input name="bank_name"></div><div class="fw-field"><label>شعبه</label><input name="branch_name"></div><div class="fw-field"><label>مبلغ (ریال)</label><input name="amount" type="number" min="1" step="1" required></div><div class="fw-field"><label>تاریخ صدور</label><input name="issue_date" type="date" value="'+today()+'"></div><div class="fw-field"><label>تاریخ سررسید</label><input name="due_date" type="date" required></div><div class="fw-field"><label>صاحب حساب</label><input name="account_holder"></div><div class="fw-field"><label>صادرکننده</label><input name="drawer_name"></div><div class="fw-field"><label>در وجه</label><input name="payee_name"></div><div class="fw-field wide"><label>توضیحات</label><input name="note" maxlength="500"></div></div><button class="fw-btn" type="submit">ذخیره چک</button></form></section>';
    shell(form+'<section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>دفتر چک‌ها</h2><p>'+money(state.cheques.length)+' چک ثبت‌شده</p></div></div>'+table(rows,['شماره','نوع','شخص','سررسید','مبلغ','وضعیت','عملیات'],'چکی ثبت نشده است.')+'</section>','مدیریت چک‌ها','ثبت و پیگیری چک‌های دریافتی و پرداختی');
  }
  function inventory(){
    const rows=state.inventoryBalances.map(x=>'<tr><td>'+esc(x.product_name)+'</td><td>'+esc(x.warehouse_name)+'</td><td>'+money(x.quantity)+'</td></tr>');
    const moves=state.stockMovements.slice(0,40).map(m=>'<tr><td>'+dateFa(m.movement_date?.slice(0,10))+'</td><td>'+esc(m.products?.name||'—')+'</td><td>'+esc(m.warehouses?.name||'—')+'</td><td>'+esc(m.movement_type)+'</td><td>'+money(m.quantity_delta)+'</td></tr>');
    const products=state.products.filter(x=>x.track_inventory).map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('');
    const warehouses=state.warehouses.map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('');
    const form='<section class="fw-card"><div class="fw-section-head"><div><h2>انتقال بین انبارها</h2><p>انتقال موجودی با محاسبه FIFO در دیتابیس</p></div></div><form data-form="transfer"><div class="fw-form-grid"><div class="fw-field"><label>انبار مبدأ</label><select name="from_warehouse_id" required>'+warehouses+'</select></div><div class="fw-field"><label>انبار مقصد</label><select name="to_warehouse_id" required>'+warehouses+'</select></div><div class="fw-field"><label>کالا</label><select name="product_id" required>'+products+'</select></div><div class="fw-field"><label>مقدار</label><input name="quantity" type="number" min="0.0001" step="0.0001" required></div><div class="fw-field"><label>تاریخ</label><input name="transfer_date" type="date" value="'+today()+'" required></div><div class="fw-field wide"><label>یادداشت</label><input name="note" maxlength="500"></div></div><button class="fw-btn" type="submit">ثبت انتقال انبار</button></form></section>';
    const openingForm='<section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>موجودی اول دوره</h2><p>ثبت موجودی اولیه با بهای تمام‌شده و لایه FIFO</p></div></div><form data-form="opening"><div class="fw-form-grid"><div class="fw-field"><label>انبار</label><select name="warehouse_id" required>'+warehouses+'</select></div><div class="fw-field"><label>کالا</label><select name="product_id" required>'+products+'</select></div><div class="fw-field"><label>تعداد</label><input name="quantity" type="number" min="0.0001" step="0.0001" required></div><div class="fw-field"><label>بهای تمام‌شده واحد (ریال)</label><input name="unit_cost" type="number" min="1" step="1" required></div><div class="fw-field"><label>تاریخ</label><input name="opening_date" type="date" value="'+today()+'" required></div><div class="fw-field wide"><label>شرح</label><input name="note" maxlength="500"></div></div><button class="fw-btn" type="submit">ثبت موجودی اول دوره</button></form></section>';
    const wastageForm='<section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>ثبت ضایعات و کسری</h2><p>کاهش موجودی با ثبت هزینه و سند حسابداری</p></div></div><form data-form="wastage"><div class="fw-form-grid"><div class="fw-field"><label>انبار</label><select name="warehouse_id" required>'+warehouses+'</select></div><div class="fw-field"><label>کالا</label><select name="product_id" required>'+products+'</select></div><div class="fw-field"><label>مقدار ضایعات</label><input name="quantity" type="number" min="0.0001" step="0.0001" required></div><div class="fw-field"><label>تاریخ</label><input name="wastage_date" type="date" value="'+today()+'" required></div><div class="fw-field wide"><label>علت / شرح</label><input name="reason" maxlength="500" required></div></div><button class="fw-btn" type="submit">ثبت ضایعات</button></form></section>';
    shell(form+openingForm+wastageForm+'<section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>مانده موجودی</h2><p>بر اساس گردش‌های ثبت‌شده</p></div></div>'+table(rows,['کالا','انبار','موجودی'],'گردش انباری برای محاسبه موجودی ثبت نشده است.')+'</section><section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>آخرین گردش‌ها</h2></div></div>'+table(moves,['تاریخ','کالا','انبار','نوع گردش','مقدار'],'گردش انباری وجود ندارد.')+'</section>','انبار و موجودی','موجودی انبارها و گردش کالا');
  }


  function legacy(){
    const summary=(state.legacyPreview?.collections||[]).map(x=>'<tr><td>'+esc(x.collection)+'</td><td>'+money(x.active)+'</td><td>'+money(x.invalid_object_payloads||0)+'</td><td>'+money(x.payload_id_mismatches||0)+'</td></tr>');
    const financial=(state.legacyReconciliation?.financial_collections_deferred||state.legacyImportResult?.reconciliation?.financial_collections_deferred||[]).map(x=>'<tr><td>'+esc(x.collection)+'</td><td>'+money(x.total)+'</td></tr>');
    const safe=state.legacyPreview?.safe_to_import===true;
    const importResult=state.legacyImportResult?'<section class="fw-card" style="margin-top:16px"><h2>نتیجه ورود داده</h2><pre>'+esc(JSON.stringify(state.legacyImportResult,null,2))+'</pre></section>':'';
    const reconciliation=state.legacyReconciliation||state.legacyImportResult?.reconciliation;
    shell('<section class="fw-card"><div class="fw-section-head"><div><h2>انتقال سوابق اپلیکیشن به حساب مشترک</h2><p>ابتدا بررسی فقط‌خواندنی اجرا می‌شود؛ سپس فقط اطلاعات پشتیبانی‌شده و بدون تعارض وارد جداول اصلی می‌شوند.</p></div></div><div class="fw-actions"><button class="fw-btn secondary" data-action="legacy-preview">بررسی و پیش‌نمایش داده‌ها</button><button class="fw-btn" data-action="legacy-import" '+(safe?'':'disabled')+'>ورود اطلاعات تأییدشده</button></div>'+(state.legacyPreview?'<p class="fw-sub">'+(safe?'پیش‌بررسی موفق است؛ داده‌های پشتیبانی‌شده آماده ورود هستند.':'ورود متوقف شد؛ ابتدا خطاها یا ارجاع‌های ناقص باید بررسی شوند.')+'</p>'+table(summary,['مجموعه','رکورد فعال','ساختار نامعتبر','شناسه ناسازگار'],'داده‌ای برای پیش‌نمایش وجود ندارد.'):'<div class="fw-empty">برای مشاهده وضعیت، پیش‌بررسی را اجرا کنید.</div>')+'</section>'+ (reconciliation?'<section class="fw-card" style="margin-top:16px"><h2>موارد مالی که هنوز به تبدیل حسابداری نیاز دارند</h2><p class="fw-sub">این سوابق حذف نمی‌شوند و فعلاً به‌صورت داده خام در نسخه وب قابل مشاهده‌اند؛ تا زمان نگاشت و تطبیق حسابداری، به دفتر مالی اصلی منتقل نمی‌شوند.</p>'+table(financial,['مجموعه قدیمی','تعداد رکورد'],'مورد مالی معوقی گزارش نشده است.')+'</section>':'')+importResult,'همگام‌سازی و ورود داده','ورود کنترل‌شده سوابق قبلی از اپلیکیشن به پایگاه داده مشترک');
  }

  function render(){
    if(!state.user){authView();return;}
    if(!state.business){root.innerHTML='<div class="fw-auth-wrap"><section class="fw-auth-card"><div class="fw-brand"><div class="fw-brand-mark">ف</div><div><b>فاکتوری</b><small>حسابداری آنلاین</small></div></div><h1>ساخت کسب‌وکار</h1><p class="fw-sub">برای شروع، نام کسب‌وکار خود را وارد کنید.</p><form data-form="business"><div class="fw-field"><label>نام کسب‌وکار</label><input name="name" required minlength="2" maxlength="160"></div><button class="fw-btn fw-full" type="submit">ایجاد فضای حسابداری</button></form><button class="fw-link" data-action="logout" style="margin-top:16px">خروج از حساب</button></section></div>';return;}
    ({dashboard,invoices,contacts,products,finance,cheques,inventory,legacy}[state.section]||dashboard)();
  }
  async function withBusy(fn){
    if(state.busy)return;state.busy=true;root.classList.add('fw-busy');
    try{await fn();}catch(e){toast(e.message||'خطا در انجام عملیات');}
    finally{state.busy=false;root.classList.remove('fw-busy');}
  }
  root.addEventListener('click',e=>{
    const section=e.target.closest('[data-section]');
    if(section){state.section=section.dataset.section;render();return;}
    const btn=e.target.closest('[data-action]');if(!btn)return;
    const action=btn.dataset.action;
    if(action==='toggle-auth'){state.signup=!state.signup;render();}
    if(action==='logout')withBusy(async()=>{try{await request('/auth/v1/logout',{method:'POST'});}catch(_){}saveSession(null);state.user=null;state.business=null;state.businesses=[];clearData();render();});
    if(action==='refresh')withBusy(async()=>{await loadBusinesses();render();toast('اطلاعات بروزرسانی شد.');});
    if(action==='legacy-preview')withBusy(async()=>{const [preview,reconciliation]=await Promise.all([rpc('preview_legacy_normalization',{p_business_id:state.business.id}),rpc('reconcile_legacy_normalization',{p_business_id:state.business.id})]);state.legacyPreview=preview;state.legacyReconciliation=reconciliation;state.legacyImportResult=null;render();toast('پیش‌بررسی داده‌ها انجام شد.');});
    if(action==='legacy-import')withBusy(async()=>{if(state.legacyPreview?.safe_to_import!==true)throw new Error('ابتدا پیش‌بررسی موفق و بدون تعارض اجرا کنید.');const result=await rpc('web_import_legacy_supported_data',{p_business_id:state.business.id,p_import_generation:crypto.randomUUID()});state.legacyImportResult=result;state.legacyPreview=result.preflight||state.legacyPreview;state.legacyReconciliation=result.reconciliation||null;await loadData();render();toast(result.imported?'ورود داده‌های پشتیبانی‌شده انجام شد.':'ورود داده به دلیل وضعیت پیش‌بررسی متوقف شد.');});
    if(action==='cheque-status')withBusy(async()=>{const cheque=state.cheques.find(x=>x.id===btn.dataset.id);if(!cheque)return;let account=null;if(btn.dataset.status==='cleared'){account=state.accounts.find(x=>x.is_default)||state.accounts[0];if(!account)throw new Error('برای تسویه چک ابتدا حساب مالی بسازید.');}if(!confirm('وضعیت چک تغییر کند؟ در صورت تسویه، سند مالی ثبت می‌شود.'))return;await rpc('transition_cheque',{p_business_id:state.business.id,p_cheque_id:cheque.id,p_to_status:btn.dataset.status,p_event_date:today(),p_financial_account_id:account?.id||null,p_note:'تغییر وضعیت از نسخه وب',p_idempotency_key:idempotency()});await loadData();render();toast('وضعیت چک به‌روزرسانی شد.');});
    if(action==='post-invoice')withBusy(async()=>{
      const doc=state.documents.find(x=>x.id===btn.dataset.id);if(!doc)return;
      const fn=doc.document_type==='purchase'?'post_purchase_document':doc.document_type==='goods_sale'?'post_goods_sale_document':(['service_sale','service_purchase'].includes(doc.document_type)?'post_service_document':null);
      if(!fn){toast('ثبت نهایی این نوع سند از این مسیر پشتیبانی نمی‌شود.');return;}
      if(!confirm('فاکتور پس از ثبت نهایی وارد حسابداری و گردش موجودی می‌شود. ادامه می‌دهید؟'))return;
      await rpc(fn,{p_business_id:state.business.id,p_document_id:doc.id,p_idempotency_key:idempotency()});
      await loadData();render();toast('فاکتور با موفقیت ثبت نهایی شد.');
    });
  });
  root.addEventListener('change',e=>{
    if(e.target.id==='fw-business')withBusy(async()=>{state.business=state.businesses.find(b=>b.id===e.target.value)||null;await loadData();state.section='dashboard';render();});
    if(e.target.name==='product_id'){const opt=e.target.selectedOptions[0];const price=root.querySelector('[name="unit_price"]');if(price&&opt?.dataset.price)price.value=opt.dataset.price;}
  });
  root.addEventListener('submit',e=>{
    const form=e.target.closest('form[data-form]');if(!form)return;e.preventDefault();
    const data=Object.fromEntries(new FormData(form).entries());const kind=form.dataset.form;
    withBusy(async()=>{
      if(kind==='auth'){
        await auth(state.signup?'signup':'signin',data.email,data.password,data.name||'');
        if(state.session?.access_token){state.user=await request('/auth/v1/user');await loadBusinesses();render();}
      } else if(kind==='business'){
        const id=await rpc('create_business',{p_name:data.name});
        await loadBusinesses();render();toast('فضای حسابداری ایجاد شد.');
      } else if(kind==='contact'){
        await rpc('web_create_contact',{p_business_id:state.business.id,p_contact_type:data.contact_type,p_name:data.name,p_phone:data.phone||null,p_code:data.code||null,p_address:data.address||null,p_notes:null});
        await loadData();render();toast('شخص با موفقیت ذخیره شد.');
      } else if(kind==='product'){
        await rpc('web_create_product',{p_business_id:state.business.id,p_name:data.name,p_sku:data.sku||null,p_unit_name:data.unit_name||'عدد',p_sale_price:Number(data.sale_price||0),p_track_inventory:form.querySelector('[name="track_inventory"]').checked,p_minimum_stock:0,p_barcode:null});
        await loadData();render();toast('کالا با موفقیت ذخیره شد.');
      } else if(kind==='finance'){
        const type=data.transaction_type;const contactId=data.contact_id||null;const amount=Number(data.amount);if(!Number.isSafeInteger(amount)||amount<=0)throw new Error('مبلغ باید عدد صحیح و مثبت باشد.');if(type==='customer_receipt'){if(!contactId)throw new Error('برای دریافت از مشتری، شخص را انتخاب کنید.');await rpc('post_customer_receipt',{p_business_id:state.business.id,p_contact_id:contactId,p_financial_account_id:data.account_id,p_amount:amount,p_transaction_date:data.transaction_date,p_document_id:null,p_allocated_amount:0,p_reference_number:data.reference_number||null,p_description:data.description||null,p_idempotency_key:idempotency()});}else{await rpc('post_simple_financial_transaction',{p_business_id:state.business.id,p_transaction_type:type,p_contact_id:type==='supplier_payment'?contactId:null,p_financial_account_id:data.account_id,p_amount:amount,p_transaction_date:data.transaction_date,p_reference_number:data.reference_number||null,p_description:data.description||null,p_idempotency_key:idempotency()});}await loadData();render();toast('عملیات مالی با موفقیت ثبت شد.');
      } else if(kind==='cheque'){
        const amount=Number(data.amount);if(!Number.isSafeInteger(amount)||amount<=0)throw new Error('مبلغ چک باید عدد صحیح و مثبت باشد.');await rpc('create_cheque',{p_business_id:state.business.id,p_cheque_direction:data.cheque_direction,p_contact_id:data.contact_id,p_cheque_number:data.cheque_number,p_sayad_id:data.sayad_id||null,p_bank_name:data.bank_name||null,p_branch_name:data.branch_name||null,p_account_number:null,p_account_holder:data.account_holder||null,p_drawer_name:data.drawer_name||null,p_payee_name:data.payee_name||null,p_amount:amount,p_issue_date:data.issue_date||null,p_due_date:data.due_date,p_note:data.note||null,p_idempotency_key:idempotency()});await loadData();render();toast('چک ثبت شد.');
      } else if(kind==='opening'){
        const quantity=Number(data.quantity),unitCost=Number(data.unit_cost);if(!(quantity>0)||!Number.isSafeInteger(unitCost)||unitCost<=0)throw new Error('تعداد و بهای تمام‌شده باید معتبر و مثبت باشند.');await rpc('post_inventory_opening',{p_business_id:state.business.id,p_opening_date:data.opening_date,p_note:data.note||null,p_items:[{product_id:data.product_id,warehouse_id:data.warehouse_id,quantity,unit_cost:unitCost}],p_idempotency_key:idempotency()});await loadData();render();toast('موجودی اول دوره ثبت شد.');
      } else if(kind==='wastage'){
        const quantity=Number(data.quantity);if(!(quantity>0))throw new Error('مقدار ضایعات معتبر نیست.');await rpc('post_inventory_wastage',{p_business_id:state.business.id,p_wastage_date:data.wastage_date,p_reason:data.reason,p_items:[{product_id:data.product_id,warehouse_id:data.warehouse_id,quantity}],p_idempotency_key:idempotency()});await loadData();render();toast('ضایعات ثبت شد.');
      } else if(kind==='transfer'){
        if(data.from_warehouse_id===data.to_warehouse_id)throw new Error('انبار مبدأ و مقصد باید متفاوت باشند.');const quantity=Number(data.quantity);if(!(quantity>0))throw new Error('مقدار انتقال معتبر نیست.');await rpc('post_stock_transfer',{p_business_id:state.business.id,p_from_warehouse_id:data.from_warehouse_id,p_to_warehouse_id:data.to_warehouse_id,p_transfer_date:data.transfer_date,p_note:data.note||null,p_items:[{product_id:data.product_id,quantity}],p_idempotency_key:idempotency()});await loadData();render();toast('انتقال انبار ثبت شد.');
      } else if(kind==='service'){
        const price=Number(data.sale_price);if(!Number.isSafeInteger(price)||price<0)throw new Error('قیمت خدمت باید عدد صحیح و غیرمنفی باشد.');await rpc('web_create_service',{p_business_id:state.business.id,p_name:data.name,p_description:data.description||null,p_sale_price:price});await loadData();render();toast('خدمت ذخیره و با اپ همگام شد.');
      } else if(kind==='invoice'){
        const serviceSale=data.document_type==='service_sale';const p=serviceSale?state.services.find(x=>x.id===data.service_id):state.products.find(x=>x.id===data.product_id);if(!p)throw new Error(serviceSale?'خدمت انتخاب‌شده معتبر نیست.':'کالای انتخاب‌شده معتبر نیست.');
        const item=serviceSale?{item_type:'service',service_id:p.id,description:p.name,quantity:Number(data.quantity),unit_name:'خدمت',unit_price:Number(data.unit_price),discount_amount:0,tax_rate:0}:{item_type:'goods',product_id:p.id,description:p.name,quantity:Number(data.quantity),unit_name:p.unit_name||'عدد',unit_price:Number(data.unit_price),discount_amount:0,tax_rate:0};
        const payload={p_business_id:state.business.id,p_document_type:data.document_type||'goods_sale',p_contact_id:data.contact_id,p_warehouse_id:data.warehouse_id||null,p_fiscal_period_id:null,p_document_date:data.document_date||today(),p_due_date:null,p_notes:data.notes||null,p_discount_amount:0,p_tax_rate:0,p_items:[item],p_idempotency_key:idempotency()};
        await rpc('create_document_draft',payload);await loadData();render();toast('پیش‌نویس فاکتور ذخیره شد و با اپ همگام شد.');
      }
    });
  });
  if(!base||!key){root.innerHTML='<div class="fw-auth-wrap"><section class="fw-auth-card"><h1>اتصال کامل نیست</h1><p class="fw-sub">تنظیمات Supabase را در بخش تنظیمات ← Factoori Web بررسی کنید.</p></section></div>';return;}
  restore();
})();