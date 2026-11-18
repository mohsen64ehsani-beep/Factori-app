(() => {
  'use strict';
  const cfg = window.FACTOORI_WEB_CONFIG || {};
  const root = document.getElementById('factoori-web-root');
  if (!root) return;
  const base = String(cfg.supabaseUrl || '').replace(/\/$/, '');
  const key = String(cfg.publishableKey || '');
  const storageKey = 'factoori_web_session_v1';
  const state = {session:null,user:null,businesses:[],business:null,contacts:[],products:[],documents:[],warehouses:[],accounts:[],section:'dashboard',signup:false,busy:false};
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
    if(data.user) state.user=data.user;
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
  function clearData(){state.contacts=[];state.products=[];state.documents=[];state.warehouses=[];state.accounts=[];}
  async function loadData(){
    const b=state.business?.id;if(!b){clearData();return;}
    const f='business_id=eq.'+encodeURIComponent(b);
    const results=await Promise.all([
      rest('contacts','select=id,name,contact_type,phone,code,is_active&'+f+'&is_active=eq.true&order=name.asc&limit=200'),
      rest('products','select=id,name,sku,unit_name,sale_price,track_inventory,is_active&'+f+'&is_active=eq.true&order=name.asc&limit=200'),
      rest('documents','select=id,document_type,document_number,document_date,total_amount,status,contact_id,created_at&'+f+'&order=created_at.desc&limit=50'),
      rest('warehouses','select=id,name,is_default,is_active&'+f+'&is_active=eq.true&order=is_default.desc,name.asc'),
      rest('financial_accounts','select=id,name,account_type,is_default,is_active&'+f+'&is_active=eq.true&order=is_default.desc,name.asc')
    ]);
    [state.contacts,state.products,state.documents,state.warehouses,state.accounts]=results.map(x=>x||[]);
  }
  function authView(){
    root.innerHTML='<div class="fw-auth-wrap"><section class="fw-auth-card"><div class="fw-brand"><div class="fw-brand-mark">ف</div><div><b>فاکتوری</b><small>سیستم یکپارچه حسابداری</small></div></div><h1>'+(state.signup?'ساخت حساب کاربری':'خوش آمدید')+'</h1><p class="fw-sub">با همان حساب اپلیکیشن اندروید وارد شوید؛ اطلاعات در هر دو نسخه مشترک است.</p><form data-form="auth">'+(state.signup?'<div class="fw-field"><label>نام و نام خانوادگی</label><input name="name" autocomplete="name" required placeholder="نام شما"></div>':'')+'<div class="fw-field"><label>ایمیل</label><input name="email" type="email" autocomplete="email" required placeholder="name@example.com" dir="ltr"></div><div class="fw-field"><label>رمز عبور</label><input name="password" type="password" autocomplete="'+(state.signup?'new-password':'current-password')+'" minlength="8" required placeholder="حداقل ۸ کاراکتر" dir="ltr"></div><button class="fw-btn fw-full" type="submit">'+(state.signup?'ایجاد حساب':'ورود به حساب')+'</button></form><div class="fw-auth-toggle">'+(state.signup?'قبلاً حساب دارید؟':'حساب ندارید؟')+' <button class="fw-link" data-action="toggle-auth">'+(state.signup?'ورود':'ثبت‌نام')+'</button></div><div class="fw-auth-toggle">اطلاعات ورود اپلیکیشن و نسخه وب یکسان است.</div></section></div>';
  }
  function shell(content,title,subtitle='مدیریت یکپارچه کسب‌وکار شما'){
    const nav=[['dashboard','▦','داشبورد'],['invoices','▤','فاکتورها'],['contacts','♙','اشخاص'],['products','◇','کالاها']];
    root.innerHTML='<div class="fw-layout"><aside class="fw-sidebar"><div class="fw-brand"><div class="fw-brand-mark">ف</div><div><b>فاکتوری</b><small>حسابداری آنلاین</small></div></div><div class="fw-business"><small>کسب‌وکار فعال</small><select id="fw-business">'+state.businesses.map(b=>'<option value="'+esc(b.id)+'" '+(b.id===state.business?.id?'selected':'')+'>'+esc(b.name)+'</option>').join('')+'</select></div><nav class="fw-nav">'+nav.map(n=>'<button data-section="'+n[0]+'" class="'+(state.section===n[0]?'active':'')+'"><i>'+n[1]+'</i>'+n[2]+'</button>').join('')+'</nav><div class="fw-side-bottom">'+(cfg.purchaseUrl?'<a class="fw-purchase" href="'+esc(cfg.purchaseUrl)+'" target="_blank" rel="noopener">★ ارتقا به نسخه حرفه‌ای</a>':'')+'<div class="fw-user">'+esc(state.user?.email||'')+'</div><button class="fw-btn ghost fw-full" data-action="logout">خروج از حساب</button></div></aside><main class="fw-main"><div class="fw-content"><header class="fw-topbar"><div><h1>'+title+'</h1><p>'+subtitle+'</p></div><div class="fw-top-actions">'+(cfg.purchaseUrl?'<a class="fw-purchase" href="'+esc(cfg.purchaseUrl)+'" target="_blank" rel="noopener">★ نسخه حرفه‌ای</a>':'')+'<button class="fw-btn ghost" data-action="refresh">↻ بروزرسانی</button></div></header>'+content+'</div></main></div>';
  }
  function table(rows,heads,empty){
    if(!rows.length)return '<div class="fw-empty">'+empty+'</div>';
    return '<div class="fw-table-wrap"><table class="fw-table"><thead><tr>'+heads.map(h=>'<th>'+h+'</th>').join('')+'</tr></thead><tbody>'+rows.join('')+'</tbody></table></div>';
  }
  function dashboard(){
    const sales=state.documents.filter(d=>d.document_type==='goods_sale'||d.document_type==='service_sale');
    const drafts=state.documents.filter(d=>d.status==='draft').length;
    const total=sales.reduce((a,d)=>a+Number(d.total_amount||0),0);
    const latest=state.documents.slice(0,6).map(d=>'<tr><td>'+esc(d.document_number||'پیش‌نویس')+'</td><td>'+dateFa(d.document_date)+'</td><td>'+money(d.total_amount)+'</td><td><span class="fw-badge '+(d.status==='posted'?'green':'gray')+'">'+(d.status==='posted'?'ثبت نهایی':'پیش‌نویس')+'</span></td></tr>');
    shell('<div class="fw-grid"><section class="fw-card fw-stat"><div><small>اشخاص ثبت‌شده</small><strong>'+money(state.contacts.length)+'</strong></div><span class="fw-stat-icon">♙</span></section><section class="fw-card fw-stat"><div><small>کالاها و خدمات</small><strong>'+money(state.products.length)+'</strong></div><span class="fw-stat-icon">◇</span></section><section class="fw-card fw-stat"><div><small>فاکتورهای فروش</small><strong>'+money(sales.length)+'</strong></div><span class="fw-stat-icon">▤</span></section><section class="fw-card fw-stat"><div><small>جمع فروش ثبت‌شده</small><strong>'+money(total)+'</strong></div><span class="fw-stat-icon">ت</span></section></div><section class="fw-card"><div class="fw-section-head"><div><h2>آخرین فاکتورها</h2><p>'+money(drafts)+' پیش‌نویس در انتظار ثبت نهایی</p></div><button class="fw-btn secondary" data-section="invoices">مشاهده همه</button></div>'+table(latest,['شماره','تاریخ','مبلغ (ریال)','وضعیت'],'هنوز فاکتوری ثبت نشده است.')+'</section>','داشبورد','نمای کلی عملکرد کسب‌وکار '+esc(state.business?.name||'')); 
  }
  function contacts(){
    const rows=state.contacts.map(c=>'<tr><td>'+esc(c.name)+'</td><td>'+({customer:'مشتری',supplier:'تأمین‌کننده',both:'مشتری و تأمین‌کننده'}[c.contact_type]||'—')+'</td><td>'+esc(c.phone||'—')+'</td><td>'+esc(c.code||'—')+'</td></tr>');
    shell('<div class="fw-two"><section class="fw-card"><div class="fw-section-head"><div><h2>افزودن شخص جدید</h2><p>ثبت مشتری یا تأمین‌کننده</p></div></div><form data-form="contact"><div class="fw-field"><label>نام شخص / شرکت</label><input name="name" required maxlength="160"></div><div class="fw-field"><label>نوع شخص</label><select name="contact_type"><option value="customer">مشتری</option><option value="supplier">تأمین‌کننده</option><option value="both">هر دو</option></select></div><div class="fw-field"><label>شماره تماس</label><input name="phone" inputmode="tel"></div><div class="fw-field"><label>کد / شناسه</label><input name="code"></div><div class="fw-field"><label>نشانی</label><input name="address"></div><button class="fw-btn fw-full" type="submit">ذخیره شخص</button></form></section><section class="fw-card"><div class="fw-section-head"><div><h2>دفتر اشخاص</h2><p>'+money(state.contacts.length)+' شخص فعال</p></div></div>'+table(rows,['نام','نوع','تلفن','کد'],'هنوز شخصی ثبت نشده است.')+'</section></div>','دفتر اشخاص','مشتریان و تأمین‌کنندگان مشترک میان اپلیکیشن و وب'); 
  }
  function products(){
    const rows=state.products.map(p=>'<tr><td>'+esc(p.name)+'</td><td>'+esc(p.sku||'—')+'</td><td>'+esc(p.unit_name||'عدد')+'</td><td>'+money(p.sale_price)+'</td><td>'+(p.track_inventory?'فعال':'غیرفعال')+'</td></tr>');
    shell('<div class="fw-two"><section class="fw-card"><div class="fw-section-head"><div><h2>افزودن کالا</h2><p>کالای جدید در حساب مشترک</p></div></div><form data-form="product"><div class="fw-field"><label>نام کالا</label><input name="name" required maxlength="160"></div><div class="fw-field"><label>کد کالا</label><input name="sku"></div><div class="fw-field"><label>واحد</label><input name="unit_name" value="عدد"></div><div class="fw-field"><label>قیمت فروش (ریال)</label><input name="sale_price" type="number" min="0" step="1" value="0" required></div><div class="fw-field"><label><input type="checkbox" name="track_inventory" checked style="width:auto;min-height:auto"> کنترل موجودی</label></div><button class="fw-btn fw-full" type="submit">ذخیره کالا</button></form></section><section class="fw-card"><div class="fw-section-head"><div><h2>فهرست کالاها</h2><p>'+money(state.products.length)+' کالای فعال</p></div></div>'+table(rows,['نام کالا','کد','واحد','قیمت فروش (ریال)','موجودی'],'هنوز کالایی ثبت نشده است.')+'</section></div>','کالاها و خدمات','مدیریت فهرست کالاهای کسب‌وکار'); 
  }
  function invoices(){
    const rows=state.documents.map(d=>'<tr><td>'+esc(d.document_number||'—')+'</td><td>'+({goods_sale:'فروش کالا',service_sale:'فروش خدمات',purchase:'خرید کالا',service_purchase:'خرید خدمات'}[d.document_type]||esc(d.document_type))+'</td><td>'+dateFa(d.document_date)+'</td><td>'+money(d.total_amount)+'</td><td><span class="fw-badge '+(d.status==='posted'?'green':'gray')+'">'+(d.status==='posted'?'ثبت نهایی':'پیش‌نویس')+'</span></td><td>'+(d.status==='draft'?'<button class="fw-link" data-action="post-invoice" data-id="'+esc(d.id)+'">ثبت نهایی</button>':'—')+'</td></tr>');
    const customers=state.contacts.filter(c=>['customer','both'].includes(c.contact_type));
    const products=state.products;
    const form='<section class="fw-card"><div class="fw-section-head"><div><h2>صدور پیش‌نویس فاکتور فروش</h2><p>فاکتور در پایگاه داده مشترک ذخیره می‌شود</p></div></div><form data-form="invoice"><div class="fw-form-grid"><div class="fw-field"><label>مشتری</label><select name="contact_id" required><option value="">انتخاب مشتری</option>'+customers.map(c=>'<option value="'+esc(c.id)+'">'+esc(c.name)+'</option>').join('')+'</select></div><div class="fw-field"><label>انبار</label><select name="warehouse_id"><option value="">بدون انتخاب انبار</option>'+state.warehouses.map(w=>'<option value="'+esc(w.id)+'">'+esc(w.name)+'</option>').join('')+'</select></div><div class="fw-field"><label>کالا</label><select name="product_id" required><option value="">انتخاب کالا</option>'+products.map(p=>'<option value="'+esc(p.id)+'" data-price="'+esc(p.sale_price)+'" data-unit="'+esc(p.unit_name)+'">'+esc(p.name)+'</option>').join('')+'</select></div><div class="fw-field"><label>تعداد</label><input name="quantity" type="number" min="0.0001" step="0.0001" value="1" required></div><div class="fw-field"><label>قیمت واحد (ریال)</label><input name="unit_price" type="number" min="0" step="1" required></div><div class="fw-field"><label>تاریخ فاکتور</label><input name="document_date" type="date" value="'+today()+'" required></div><div class="fw-field wide"><label>توضیحات</label><input name="notes" maxlength="500"></div></div><button class="fw-btn" type="submit">ایجاد پیش‌نویس فاکتور</button></form></section>';
    shell(form+'<section class="fw-card" style="margin-top:16px"><div class="fw-section-head"><div><h2>فاکتورهای کسب‌وکار</h2><p>'+money(state.documents.length)+' سند اخیر</p></div></div>'+table(rows,['شماره','نوع','تاریخ','مبلغ (ریال)','وضعیت','عملیات'],'فاکتوری ثبت نشده است.')+'</section>','فاکتورها','صدور و پیگیری اسناد فروش و خرید'); 
  }
  function render(){
    if(!state.user){authView();return;}
    if(!state.business){root.innerHTML='<div class="fw-auth-wrap"><section class="fw-auth-card"><div class="fw-brand"><div class="fw-brand-mark">ف</div><div><b>فاکتوری</b><small>حسابداری آنلاین</small></div></div><h1>ساخت کسب‌وکار</h1><p class="fw-sub">برای شروع، نام کسب‌وکار خود را وارد کنید.</p><form data-form="business"><div class="fw-field"><label>نام کسب‌وکار</label><input name="name" required minlength="2" maxlength="160"></div><button class="fw-btn fw-full" type="submit">ایجاد فضای حسابداری</button></form><button class="fw-link" data-action="logout" style="margin-top:16px">خروج از حساب</button></section></div>';return;}
    ({dashboard,invoices,contacts,products}[state.section]||dashboard)();
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
    if(action==='post-invoice')withBusy(async()=>{
      const doc=state.documents.find(x=>x.id===btn.dataset.id);if(!doc)return;
      const fn=doc.document_type==='purchase'?'post_purchase_document':doc.document_type==='goods_sale'?'post_goods_sale_document':null;
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
        await request('/rest/v1/contacts',{method:'POST',headers:{Prefer:'return=minimal'},body:JSON.stringify({business_id:state.business.id,contact_type:data.contact_type,name:data.name,phone:data.phone||null,code:data.code||null,address:data.address||null,created_by:state.user.id})});
        await loadData();render();toast('شخص با موفقیت ذخیره شد.');
      } else if(kind==='product'){
        await request('/rest/v1/products',{method:'POST',headers:{Prefer:'return=minimal'},body:JSON.stringify({business_id:state.business.id,name:data.name,sku:data.sku||null,unit_name:data.unit_name||'عدد',sale_price:Number(data.sale_price||0),track_inventory:form.querySelector('[name="track_inventory"]').checked,is_active:true,created_by:state.user.id})});
        await loadData();render();toast('کالا با موفقیت ذخیره شد.');
      } else if(kind==='invoice'){
        const p=state.products.find(x=>x.id===data.product_id);if(!p)throw new Error('کالای انتخاب‌شده معتبر نیست.');
        const payload={p_business_id:state.business.id,p_document_type:'goods_sale',p_contact_id:data.contact_id,p_warehouse_id:data.warehouse_id||null,p_fiscal_period_id:null,p_document_date:data.document_date||today(),p_due_date:null,p_notes:data.notes||null,p_discount_amount:0,p_tax_rate:0,p_items:[{item_type:'goods',product_id:p.id,description:p.name,quantity:Number(data.quantity),unit_name:p.unit_name||'عدد',unit_price:Number(data.unit_price),discount_amount:0,tax_rate:0}],p_idempotency_key:idempotency()};
        await rpc('create_document_draft',payload);await loadData();render();toast('پیش‌نویس فاکتور ذخیره شد.');
      }
    });
  });
  if(!base||!key){root.innerHTML='<div class="fw-auth-wrap"><section class="fw-auth-card"><h1>اتصال کامل نیست</h1><p class="fw-sub">تنظیمات Supabase را در بخش تنظیمات ← Factoori Web بررسی کنید.</p></section></div>';return;}
  restore();
})();